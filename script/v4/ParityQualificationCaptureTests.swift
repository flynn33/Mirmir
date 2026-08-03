import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Metal
import XCTest
@testable import Mirmir

final class ParityQualificationCaptureTests: XCTestCase {
    func testCaptureCPUAndMetalParityWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["MIRMIR_PARITY_CAPTURE_DIRECTORY"],
              !outputPath.isEmpty else {
            throw XCTSkip(
                "Set MIRMIR_PARITY_CAPTURE_DIRECTORY to run parity capture."
            )
        }
        let contractPath = try requiredEnvironment(
            "MIRMIR_PARITY_CONTRACT_PATH",
            in: environment
        )
        let contractData = try Data(
            contentsOf: URL(fileURLWithPath: contractPath)
        )
        let contract = try JSONDecoder().decode(
            ParityCaptureContract.self,
            from: contractData
        )
        try contract.validate()
        let contractSHA256 = sha256(contractData)
        guard contractSHA256 == (try requiredEnvironment(
            "MIRMIR_PARITY_CONTRACT_SHA256",
            in: environment
        )), contract.tools.captureSourceSHA256 == (try requiredEnvironment(
            "MIRMIR_PARITY_CAPTURE_SOURCE_SHA256",
            in: environment
        )) else {
            throw ParityCaptureError.invalidEnvironment(
                "the executing contract or capture source is not sealed"
            )
        }

        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try createNewDirectory(output)
        let runtimeMode = environment["MIRMIR_PARITY_RUNTIME_MODE"]
            ?? "production"
        let runtime = try loadRuntime(mode: runtimeMode)
        try runtime.verifyBinding()
        let runtimeRecord = try makeRuntimeRecord(
            runtime,
            mode: runtimeMode,
            expected: contract.releaseRuntime
        )
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw ParityCaptureError.metalUnavailable
        }

        var cases: [ParityCapturedCase] = []
        for definition in contract.cases {
            let directory = output
                .appendingPathComponent("cases", isDirectory: true)
                .appendingPathComponent(definition.id, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            cases.append(try await captureCase(
                definition,
                contract: contract,
                runtime: runtime,
                outputRoot: output,
                directory: directory
            ))
        }

        let capture = ParityCapture(
            schemaVersion: contract.captureSchemaVersion,
            contractSHA256: contractSHA256,
            captureSourceSHA256: contract.tools.captureSourceSHA256,
            sourceRevision: try requiredEnvironment(
                "MIRMIR_PARITY_SOURCE_REVISION",
                in: environment
            ),
            buildConfiguration: try requiredEnvironment(
                "MIRMIR_PARITY_BUILD_CONFIGURATION",
                in: environment
            ),
            processRunID: try requiredEnvironment(
                "MIRMIR_PARITY_PROCESS_RUN_ID",
                in: environment
            ),
            runtime: runtimeRecord,
            cases: cases
        )
        try canonicalJSON(capture).write(
            to: output.appendingPathComponent("capture.json"),
            options: .atomic
        )
        let manifest = try makeArtifactManifest(
            root: output,
            excluding: ["artifact-manifest.json"]
        )
        try canonicalJSON(manifest).write(
            to: output.appendingPathComponent("artifact-manifest.json"),
            options: .atomic
        )
    }
}

private enum ParityCaptureError: Error, CustomStringConvertible {
    case invalidContract(String)
    case invalidEnvironment(String)
    case invalidOutput(String)
    case invalidFixture(String)
    case parityFailure(String)
    case metalUnavailable

    var description: String {
        switch self {
        case .invalidContract(let value): "invalid parity contract: \(value)"
        case .invalidEnvironment(let value): "invalid environment: \(value)"
        case .invalidOutput(let value): "invalid parity output: \(value)"
        case .invalidFixture(let value): "invalid parity fixture: \(value)"
        case .parityFailure(let value): "parity failure: \(value)"
        case .metalUnavailable: "Metal is unavailable"
        }
    }
}

private struct ParityCaptureContract: Decodable {
    let schemaVersion: String
    let gateID: String
    let buildConfiguration: String
    let captureSchemaVersion: String
    let reportSchemaVersion: String
    let runArtifactSchemaVersion: String
    let attachmentSchemaVersion: String
    let comparison: String
    let repeatExecutionCount: Int
    let crossProcessCaptureCount: Int
    let tileSchedules: [String]
    let parityCoverage: [String]
    let releaseRuntime: ParityReleaseRuntimeContract
    let tools: ParityToolIdentities
    let cases: [ParityCaseDefinition]

    func validate() throws {
        guard schemaVersion
                == "mirmir-ash-v4-cpu-metal-parity-contract-v2",
              gateID == "deterministic-engine-v4-cpu-metal-byte-parity",
              buildConfiguration == "Release",
              captureSchemaVersion
                == "mirmir-ash-v4-cpu-metal-parity-capture-v2",
              reportSchemaVersion
                == "mirmir-ash-v4-cpu-metal-parity-report-v2",
              runArtifactSchemaVersion
                == "mirmir-ash-v4-cpu-metal-parity-run-v2",
              attachmentSchemaVersion
                == "mirmir-ash-v4-canonical-semantics-v2",
              comparison
                == "exact_visible_plane_attachment_timeline_checkpoint_and_resume_bytes",
              repeatExecutionCount == 2,
              crossProcessCaptureCount == 2,
              tileSchedules == ["row_major", "reverse", "even_then_odd"],
              Set(parityCoverage).count == parityCoverage.count,
              cases.count >= 9,
              Set(cases.map(\.id)).count == cases.count else {
            throw ParityCaptureError.invalidContract("header or count mismatch")
        }
        guard Set(cases.flatMap(\.coverage)) == Set(parityCoverage) else {
            throw ParityCaptureError.invalidContract("coverage is not exact")
        }
        for value in [
            tools.captureSourceSHA256,
            tools.evaluatorSHA256,
            tools.runnerSHA256
        ] where !isSHA256(value) {
            throw ParityCaptureError.invalidContract("invalid tool identity")
        }
        for definition in cases {
            try definition.validate(allowedCoverage: Set(parityCoverage))
        }
    }
}

private struct ParityReleaseRuntimeContract: Decodable {
    let bundleRepositoryPath: String
    let trustRootSourceRepositoryPath: String
    let runtimeID: String
    let requiredReleaseStatus: String
}

private struct ParityToolIdentities: Codable, Equatable {
    let captureSourceSHA256: String
    let evaluatorSHA256: String
    let runnerSHA256: String
}

private struct ParityTimeDefinition: Codable, Equatable {
    let value: Int64
    let timescale: Int32
}

private struct ParityFrameDefinition: Codable, Equatable {
    let pattern: String
    let topToken: Int?
    let bottomToken: Int?
    let presentationTime: ParityTimeDefinition
    let duration: ParityTimeDefinition
    let fieldDetail: String
    let hdrProfile: String

    enum CodingKeys: String, CodingKey {
        case pattern
        case topToken
        case bottomToken
        case presentationTime
        case duration
        case fieldDetail
        case hdrProfile
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pattern, forKey: .pattern)
        if let topToken {
            try container.encode(topToken, forKey: .topToken)
        } else {
            try container.encodeNil(forKey: .topToken)
        }
        if let bottomToken {
            try container.encode(bottomToken, forKey: .bottomToken)
        } else {
            try container.encodeNil(forKey: .bottomToken)
        }
        try container.encode(presentationTime, forKey: .presentationTime)
        try container.encode(duration, forKey: .duration)
        try container.encode(fieldDetail, forKey: .fieldDetail)
        try container.encode(hdrProfile, forKey: .hdrProfile)
    }
}

private struct ParityStateExpectation: Codable, Equatable {
    let inputOrdinal: Int
    let dominance: String?
    let classification: String?
    let cadenceID: String
    let historyGeneration: UInt64

    enum CodingKeys: String, CodingKey {
        case inputOrdinal
        case dominance
        case classification
        case cadenceID
        case historyGeneration
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputOrdinal, forKey: .inputOrdinal)
        if let dominance {
            try container.encode(dominance, forKey: .dominance)
        } else {
            try container.encodeNil(forKey: .dominance)
        }
        if let classification {
            try container.encode(classification, forKey: .classification)
        } else {
            try container.encodeNil(forKey: .classification)
        }
        try container.encode(cadenceID, forKey: .cadenceID)
        try container.encode(historyGeneration, forKey: .historyGeneration)
    }
}

private struct ParityCaseDefinition: Codable, Equatable {
    let id: String
    let kind: String
    let storage: String
    let association: String
    let scanMode: String
    let sourceWidth: Int
    let sourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int
    let frames: [ParityFrameDefinition]
    let checkpointBoundaries: [Int]
    let stateExpectations: [ParityStateExpectation]
    let coverage: [String]

    func validate(allowedCoverage: Set<String>) throws {
        let kinds = [
            "pixel_spatial",
            "pixel_temporal",
            "pixel_interlaced_temporal",
            "alpha_spatial"
        ]
        guard id.range(
            of: "^[a-z0-9][a-z0-9-]*$",
            options: .regularExpression
        ) != nil,
        kinds.contains(kind),
        ["progressive", "interlaced_tff", "interlaced_bff"]
            .contains(scanMode),
        sourceWidth > 0,
        sourceHeight > 0,
        targetWidth >= sourceWidth,
        targetHeight >= sourceHeight,
        targetWidth > sourceWidth || targetHeight > sourceHeight,
        !frames.isEmpty,
        !coverage.isEmpty,
        Set(coverage).count == coverage.count,
        Set(coverage).isSubset(of: allowedCoverage),
        checkpointBoundaries == Array(Set(checkpointBoundaries)).sorted(),
        checkpointBoundaries.allSatisfy({ $0 >= 0 && $0 < frames.count - 1 })
        else {
            throw ParityCaptureError.invalidContract("invalid case \(id)")
        }
        if kind == "pixel_interlaced_temporal", scanMode == "progressive" {
            throw ParityCaptureError.invalidContract(
                "interlaced case \(id) has progressive scan mode"
            )
        }
        if kind != "pixel_interlaced_temporal", scanMode != "progressive" {
            throw ParityCaptureError.invalidContract(
                "non-interlaced case \(id) has an interlaced scan mode"
            )
        }
    }
}

private struct ParityRuntimeRecord: Codable, Equatable {
    let mode: String
    let runtimeID: String
    let releaseStatus: String
    let manifestSHA256: String
    let manifestFileSHA256: String
    let sourceRevision: String
    let builderSourceSHA256: String
    let trustRootConfigured: Bool
    let bindingVerified: Bool
}

private struct ParityArtifact: Codable, Equatable {
    let path: String
    let byteCount: Int
    let sha256: String
}

private struct ParityRunArtifacts: Codable, Equatable {
    let visible: ParityArtifact
    let semantics: ParityArtifact
    let checkpoints: ParityArtifact
    let resume: ParityArtifact
}

private struct ParityScheduleRun: Codable, Equatable {
    let schedule: String
    let run: ParityRunArtifacts
}

private struct ParityBackendRunSet: Codable, Equatable {
    let canonical: ParityRunArtifacts
    let repeatRun: ParityRunArtifacts
    let schedules: [ParityScheduleRun]

    enum CodingKeys: String, CodingKey {
        case canonical
        case repeatRun = "repeat"
        case schedules
    }
}

private struct ParityCapturedCase: Codable, Equatable {
    let id: String
    let definition: ParityCaseDefinition
    let cpu: ParityBackendRunSet
    let metal: ParityBackendRunSet
    let metadata: ParityArtifact
}

private struct ParityCapture: Codable, Equatable {
    let schemaVersion: String
    let contractSHA256: String
    let captureSourceSHA256: String
    let sourceRevision: String
    let buildConfiguration: String
    let processRunID: String
    let runtime: ParityRuntimeRecord
    let cases: [ParityCapturedCase]
}

private struct ParityArtifactManifest: Codable {
    let schemaVersion: String
    let artifacts: [ParityArtifact]
}

private struct ParityCaseMetadata: Codable {
    let id: String
    let sourceWidth: Int
    let sourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int
    let horizontalUniquePhaseCount: Int
    let verticalUniquePhaseCount: Int
    let spatialPlanSHA256: String
    let kernelIRSHA256: String
    let cpuSourcePaddingByteCount: Int
    let cpuDestinationPaddingByteCount: Int
    let metalSourcePaddingByteCount: Int
    let metalDestinationPaddingByteCount: Int
    let cpuPaddingSentinelPreserved: Bool
    let metalPaddingSentinelPreserved: Bool
}

private struct ParityTimeRecord: Codable, Equatable {
    let value: Int64
    let timescale: Int32
    let flags: UInt32
    let epoch: Int64

    init(_ time: CMTime) throws {
        guard time.isNumeric, time.timescale > 0 else {
            throw ParityCaptureError.invalidFixture("non-numeric CMTime")
        }
        value = time.value
        timescale = time.timescale
        flags = time.flags.rawValue
        epoch = time.epoch
    }
}

private struct ParityInputTiming: Codable, Equatable {
    let presentationTime: ParityTimeRecord
    let duration: ParityTimeRecord
}

private struct ParityAttachmentDictionaryEntry: Encodable, Equatable {
    let key: String
    let value: ParityAttachmentPayload
}

private indirect enum ParityAttachmentPayload: Encodable, Equatable {
    case null
    case boolean(Bool)
    case signedInteger(String)
    case unsignedInteger(String)
    case realBits(String)
    case string(String)
    case date(String)
    case data(String)
    case array([ParityAttachmentPayload])
    case dictionary([ParityAttachmentDictionaryEntry])

    private enum CodingKeys: String, CodingKey { case kind, value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode("null", forKey: .kind)
            try container.encodeNil(forKey: .value)
        case .boolean(let value):
            try container.encode("boolean", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .signedInteger(let value):
            try container.encode("signed_integer", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .unsignedInteger(let value):
            try container.encode("unsigned_integer", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .realBits(let value):
            try container.encode("real_ieee754_binary64", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode("string", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .date(let value):
            try container.encode("date_iso8601", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .data(let value):
            try container.encode("data", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .array(let value):
            try container.encode("array", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .dictionary(let value):
            try container.encode("dictionary", forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

private struct ParityAttachmentValue: Encodable, Equatable {
    let key: String
    let mode: String
    let value: ParityAttachmentPayload
}

private struct ParitySemanticOutput: Encodable, Equatable {
    let outputOrdinal: Int
    let presentationTime: ParityTimeRecord
    let duration: ParityTimeRecord
    let sourceField: String
    let cadenceID: String
    let classification: String?
    let historyGeneration: UInt64
    let attachments: [ParityAttachmentValue]

    enum CodingKeys: String, CodingKey {
        case outputOrdinal
        case presentationTime
        case duration
        case sourceField
        case cadenceID
        case classification
        case historyGeneration
        case attachments
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outputOrdinal, forKey: .outputOrdinal)
        try container.encode(presentationTime, forKey: .presentationTime)
        try container.encode(duration, forKey: .duration)
        try container.encode(sourceField, forKey: .sourceField)
        try container.encode(cadenceID, forKey: .cadenceID)
        if let classification {
            try container.encode(classification, forKey: .classification)
        } else {
            try container.encodeNil(forKey: .classification)
        }
        try container.encode(historyGeneration, forKey: .historyGeneration)
        try container.encode(attachments, forKey: .attachments)
    }
}

private struct ParitySemanticInput: Encodable, Equatable {
    let inputOrdinal: Int
    let timing: ParityInputTiming
    let effectiveDominance: String?
    let sourceAttachments: [ParityAttachmentValue]
    let outputs: [ParitySemanticOutput]

    enum CodingKeys: String, CodingKey {
        case inputOrdinal
        case timing
        case effectiveDominance
        case sourceAttachments
        case outputs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputOrdinal, forKey: .inputOrdinal)
        try container.encode(timing, forKey: .timing)
        if let effectiveDominance {
            try container.encode(effectiveDominance, forKey: .effectiveDominance)
        } else {
            try container.encodeNil(forKey: .effectiveDominance)
        }
        try container.encode(sourceAttachments, forKey: .sourceAttachments)
        try container.encode(outputs, forKey: .outputs)
    }
}

private struct ParitySemanticsDocument: Encodable, Equatable {
    let schemaVersion = "mirmir-ash-v4-canonical-semantics-v2"
    let caseID: String
    let inputs: [ParitySemanticInput]
}

private struct ParityCheckpointEntry: Encodable, Equatable {
    let inputOrdinal: Int
    let canonicalDataBase64: String
    let canonicalSHA256: String
}

private struct ParityCheckpointSet: Encodable, Equatable {
    let schemaVersion = "mirmir-ash-v4-checkpoint-set-v2"
    let caseID: String
    let entries: [ParityCheckpointEntry]
}

private struct ParityResumeEntry: Encodable, Equatable {
    let boundaryInputOrdinal: Int
    let uninterruptedVisibleBase64: String
    let resumedVisibleBase64: String
    let uninterruptedSemanticsBase64: String
    let resumedSemanticsBase64: String
    let uninterruptedFinalCheckpointBase64: String
    let resumedFinalCheckpointBase64: String
}

private struct ParityResumeSet: Encodable, Equatable {
    let schemaVersion = "mirmir-ash-v4-resume-set-v2"
    let caseID: String
    let entries: [ParityResumeEntry]
}

private struct ParityRunBytes: Equatable {
    let visible: Data
    let semantics: Data
    let checkpoints: Data
    let resume: Data
    let sourcePaddingByteCount: Int
    let destinationPaddingByteCount: Int
    let paddingSentinelPreserved: Bool
}

private struct ParityProcessedPixelRange {
    let outputs: [CVPixelBuffer]
    let inputs: [ParitySemanticInput]
    let checkpoints: [ParityCheckpointEntry]
    let finalCheckpoint: Data
    let sourcePaddingByteCount: Int
    let destinationPaddingByteCount: Int
    let paddingSentinelPreserved: Bool
}

private func captureCase(
    _ definition: ParityCaseDefinition,
    contract: ParityCaptureContract,
    runtime: ASHVerifiedRuntimeBundleV4,
    outputRoot: URL,
    directory: URL
) async throws -> ParityCapturedCase {
    let cpu = try await captureBackendRunSet(
        definition,
        backend: .cpu,
        schedules: contract.tileSchedules,
        runtime: runtime,
        outputRoot: outputRoot,
        directory: directory
    )
    let metal = try await captureBackendRunSet(
        definition,
        backend: .metal,
        schedules: contract.tileSchedules,
        runtime: runtime,
        outputRoot: outputRoot,
        directory: directory
    )
    guard cpu.bytes == metal.bytes else {
        throw ParityCaptureError.parityFailure(
            "\(definition.id) CPU/Metal run sets differ"
        )
    }

    let plan = try SpatialScalePlanV4(
        sourceWidth: definition.sourceWidth,
        sourceHeight: definition.sourceHeight,
        targetWidth: definition.targetWidth,
        targetHeight: definition.targetHeight,
        borderRule: .reflect101
    )
    let kernel = try FixedPointKernelIRV4(scalePlan: plan)
    let metadata = ParityCaseMetadata(
        id: definition.id,
        sourceWidth: definition.sourceWidth,
        sourceHeight: definition.sourceHeight,
        targetWidth: definition.targetWidth,
        targetHeight: definition.targetHeight,
        horizontalUniquePhaseCount: plan.horizontal.uniquePhases.count,
        verticalUniquePhaseCount: plan.vertical.uniquePhases.count,
        spatialPlanSHA256: sha256(try ASHCanonicalJSONV4.encode(plan)),
        kernelIRSHA256: sha256(try ASHCanonicalJSONV4.encode(kernel)),
        cpuSourcePaddingByteCount: cpu.bytes.sourcePaddingByteCount,
        cpuDestinationPaddingByteCount: cpu.bytes.destinationPaddingByteCount,
        metalSourcePaddingByteCount: metal.bytes.sourcePaddingByteCount,
        metalDestinationPaddingByteCount: metal.bytes.destinationPaddingByteCount,
        cpuPaddingSentinelPreserved: cpu.bytes.paddingSentinelPreserved,
        metalPaddingSentinelPreserved: metal.bytes.paddingSentinelPreserved
    )
    let metadataURL = directory.appendingPathComponent("case-metadata.json")
    try canonicalJSON(metadata).write(to: metadataURL, options: .atomic)
    return ParityCapturedCase(
        id: definition.id,
        definition: definition,
        cpu: cpu.artifacts,
        metal: metal.artifacts,
        metadata: try artifact(metadataURL, relativeTo: outputRoot)
    )
}

private struct CapturedBackendRunSet {
    let bytes: ParityRunBytes
    let artifacts: ParityBackendRunSet
}

private func captureBackendRunSet(
    _ definition: ParityCaseDefinition,
    backend: FixedPointExecutionBackendV4,
    schedules: [String],
    runtime: ASHVerifiedRuntimeBundleV4,
    outputRoot: URL,
    directory: URL
) async throws -> CapturedBackendRunSet {
    let name = backend.rawValue
    let canonicalBytes = try await execute(
        definition,
        backend: backend,
        schedule: .productionFullFrame,
        runtime: runtime
    )
    let repeatBytes = try await execute(
        definition,
        backend: backend,
        schedule: .productionFullFrame,
        runtime: runtime
    )
    guard canonicalBytes == repeatBytes else {
        throw ParityCaptureError.parityFailure(
            "\(definition.id)/\(name) repeat differs"
        )
    }
    let canonical = try writeRunArtifacts(
        canonicalBytes,
        prefix: "\(name)-canonical",
        outputRoot: outputRoot,
        directory: directory
    )
    let repeatRun = try writeRunArtifacts(
        repeatBytes,
        prefix: "\(name)-repeat",
        outputRoot: outputRoot,
        directory: directory
    )
    var scheduled: [ParityScheduleRun] = []
    for name in schedules {
        let bytes = try await execute(
            definition,
            backend: backend,
            schedule: try executionSchedule(name),
            runtime: runtime
        )
        guard bytes == canonicalBytes else {
            throw ParityCaptureError.parityFailure(
                "\(definition.id)/\(backend.rawValue)/\(name) differs"
            )
        }
        scheduled.append(ParityScheduleRun(
            schedule: name,
            run: try writeRunArtifacts(
                bytes,
                prefix: "\(backend.rawValue)-schedule-\(name)",
                outputRoot: outputRoot,
                directory: directory
            )
        ))
    }
    return CapturedBackendRunSet(
        bytes: canonicalBytes,
        artifacts: ParityBackendRunSet(
            canonical: canonical,
            repeatRun: repeatRun,
            schedules: scheduled
        )
    )
}

private func writeRunArtifacts(
    _ bytes: ParityRunBytes,
    prefix: String,
    outputRoot: URL,
    directory: URL
) throws -> ParityRunArtifacts {
    func write(_ data: Data, suffix: String) throws -> ParityArtifact {
        let url = directory.appendingPathComponent("\(prefix)-\(suffix)")
        try data.write(to: url, options: .atomic)
        return try artifact(url, relativeTo: outputRoot)
    }
    return try ParityRunArtifacts(
        visible: write(bytes.visible, suffix: "visible.bin"),
        semantics: write(bytes.semantics, suffix: "semantics.json"),
        checkpoints: write(bytes.checkpoints, suffix: "checkpoints.json"),
        resume: write(bytes.resume, suffix: "resume.json")
    )
}

private func executionSchedule(
    _ value: String
) throws -> FixedPointExecutionScheduleV4 {
    switch value {
    case "row_major": .qualificationRowMajor3x2
    case "reverse": .qualificationReverse3x2
    case "even_then_odd": .qualificationEvenOdd3x2
    default:
        throw ParityCaptureError.invalidContract("unknown schedule \(value)")
    }
}

private func execute(
    _ definition: ParityCaseDefinition,
    backend: FixedPointExecutionBackendV4,
    schedule: FixedPointExecutionScheduleV4,
    runtime: ASHVerifiedRuntimeBundleV4
) async throws -> ParityRunBytes {
    if definition.kind == "alpha_spatial" {
        return try await executeAlpha(
            definition,
            backend: backend,
            schedule: schedule,
            runtime: runtime
        )
    }
    return try await executePixel(
        definition,
        backend: backend,
        schedule: schedule,
        runtime: runtime
    )
}

private func executePixel(
    _ definition: ParityCaseDefinition,
    backend: FixedPointExecutionBackendV4,
    schedule: FixedPointExecutionScheduleV4,
    runtime: ASHVerifiedRuntimeBundleV4
) async throws -> ParityRunBytes {
    let configuration = try preparedConfiguration(definition, backend: backend)
    let planSHA = ASHSHA256V4(
        rawData: Data("parity-v2:\(definition.id)".utf8)
    )
    let prepared = try makePrepared(
        configuration: configuration,
        schedule: schedule,
        runtime: runtime
    )
    let complete = try await processPixelFrames(
        definition,
        ordinals: Array(definition.frames.indices),
        prepared: prepared,
        configuration: configuration,
        runtime: runtime,
        planSHA: planSHA,
        backend: backend
    )
    let visible = try visiblePixelSequence(
        complete.outputs,
        storage: configuration.storage
    )
    let semantics = try canonicalJSON(ParitySemanticsDocument(
        caseID: definition.id,
        inputs: complete.inputs
    ))
    let checkpoints = try canonicalJSON(ParityCheckpointSet(
        caseID: definition.id,
        entries: complete.checkpoints
    ))
    var resumeEntries: [ParityResumeEntry] = []
    for boundary in definition.checkpointBoundaries {
        let prefixPrepared = try makePrepared(
            configuration: configuration,
            schedule: schedule,
            runtime: runtime
        )
        let prefix = try await processPixelFrames(
            definition,
            ordinals: Array(0...boundary),
            prepared: prefixPrepared,
            configuration: configuration,
            runtime: runtime,
            planSHA: planSHA,
            backend: backend
        )
        let resumedPrepared = try makePrepared(
            configuration: configuration,
            schedule: schedule,
            runtime: runtime
        )
        try await resumedPrepared.restoreTemporalCheckpoint(
            prefix.finalCheckpoint,
            planSHA256: planSHA
        )
        let suffix = try await processPixelFrames(
            definition,
            ordinals: Array((boundary + 1)..<definition.frames.count),
            prepared: resumedPrepared,
            configuration: configuration,
            runtime: runtime,
            planSHA: planSHA,
            backend: backend
        )
        let resumedVisible = try visiblePixelSequence(
            prefix.outputs + suffix.outputs,
            storage: configuration.storage
        )
        let resumedSemantics = try canonicalJSON(ParitySemanticsDocument(
            caseID: definition.id,
            inputs: prefix.inputs + suffix.inputs
        ))
        guard visible == resumedVisible,
              semantics == resumedSemantics,
              complete.finalCheckpoint == suffix.finalCheckpoint else {
            throw ParityCaptureError.parityFailure(
                "\(definition.id) checkpoint/resume differs at \(boundary)"
            )
        }
        resumeEntries.append(ParityResumeEntry(
            boundaryInputOrdinal: boundary,
            uninterruptedVisibleBase64: visible.base64EncodedString(),
            resumedVisibleBase64: resumedVisible.base64EncodedString(),
            uninterruptedSemanticsBase64: semantics.base64EncodedString(),
            resumedSemanticsBase64: resumedSemantics.base64EncodedString(),
            uninterruptedFinalCheckpointBase64:
                complete.finalCheckpoint.base64EncodedString(),
            resumedFinalCheckpointBase64:
                suffix.finalCheckpoint.base64EncodedString()
        ))
    }
    let resume = try canonicalJSON(ParityResumeSet(
        caseID: definition.id,
        entries: resumeEntries
    ))
    return ParityRunBytes(
        visible: visible,
        semantics: semantics,
        checkpoints: checkpoints,
        resume: resume,
        sourcePaddingByteCount: complete.sourcePaddingByteCount,
        destinationPaddingByteCount: complete.destinationPaddingByteCount,
        paddingSentinelPreserved: complete.paddingSentinelPreserved
    )
}

private func preparedConfiguration(
    _ definition: ParityCaseDefinition,
    backend: FixedPointExecutionBackendV4
) throws -> DeterministicPreparedConfigurationV4 {
    let scanMode: DeterministicScanModeV4
    switch definition.scanMode {
    case "progressive": scanMode = .progressive
    case "interlaced_tff": scanMode = .interlaced(.topFieldFirst)
    case "interlaced_bff": scanMode = .interlaced(.bottomFieldFirst)
    default:
        throw ParityCaptureError.invalidContract("invalid scan mode")
    }
    return DeterministicPreparedConfigurationV4(
        backendID: backend == .cpu
            ? .mirmirDeterministicCPU : .mirmirDeterministicMetal,
        executionBackend: backend,
        storage: try pixelStorage(definition.storage),
        sourceWidth: definition.sourceWidth,
        sourceHeight: definition.sourceHeight,
        targetWidth: definition.targetWidth,
        targetHeight: definition.targetHeight,
        scanMode: scanMode
    )
}

private func makePrepared(
    configuration: DeterministicPreparedConfigurationV4,
    schedule: FixedPointExecutionScheduleV4,
    runtime: ASHVerifiedRuntimeBundleV4
) throws -> PreparedDeterministicV4Upscaler {
    let device = configuration.executionBackend == .metal
        ? MTLCreateSystemDefaultDevice() : nil
    let library = try device.map {
        try ASHP06MetalLibraryFactoryV4.makeLibrary(
            runtime: runtime,
            device: $0
        )
    }
    return try PreparedDeterministicV4Upscaler(
        configuration: configuration,
        runtime: runtime,
        executionSchedule: schedule,
        metalDevice: device,
        metalLibrary: library
    )
}

private func processPixelFrames(
    _ definition: ParityCaseDefinition,
    ordinals: [Int],
    prepared: PreparedDeterministicV4Upscaler,
    configuration: DeterministicPreparedConfigurationV4,
    runtime: ASHVerifiedRuntimeBundleV4,
    planSHA: ASHSHA256V4,
    backend: FixedPointExecutionBackendV4
) async throws -> ParityProcessedPixelRange {
    var buffers: [CVPixelBuffer] = []
    var semanticInputs: [ParitySemanticInput] = []
    var checkpointEntries: [ParityCheckpointEntry] = []
    var finalCheckpoint = Data()
    var sourcePaddingByteCount = 0
    var destinationPaddingByteCount = 0
    var paddingPreserved = true
    for ordinal in ordinals {
        let frame = definition.frames[ordinal]
        let source = try makePixelBuffer(
            storage: configuration.storage,
            width: definition.sourceWidth,
            height: definition.sourceHeight,
            metalCompatible: backend == .metal
        )
        try fillAllStorageBytes(source, sentinel: 0xA7)
        try PixelBufferSignalCodecV4.write(
            makeSignalFrame(
                storage: configuration.storage,
                width: definition.sourceWidth,
                height: definition.sourceHeight,
                frame: frame
            ),
            to: source
        )
        try installPixelAttachments(
            on: source,
            storage: configuration.storage,
            frame: frame
        )
        let sourceAttachments = try frameAttachments(source)
        let sourcePaddingBefore = try paddingBytes(
            source,
            storage: configuration.storage
        )
        let outputCount = prepared.maximumOutputFramesPerInput
        var destinations: [FramePixelBuffer] = []
        for _ in 0..<outputCount {
            let destination = try makePixelBuffer(
                storage: configuration.storage,
                width: definition.targetWidth,
                height: definition.targetHeight,
                metalCompatible: backend == .metal
            )
            try fillAllStorageBytes(destination, sentinel: 0xD3)
            destinations.append(FramePixelBuffer(destination))
        }
        let presentationTime = CMTime(
            value: frame.presentationTime.value,
            timescale: frame.presentationTime.timescale
        )
        let duration = CMTime(
            value: frame.duration.value,
            timescale: frame.duration.timescale
        )
        let outputs = try await prepared.processTemporal(
            source: FramePixelBuffer(source),
            destinations: destinations,
            timing: FrameTiming(
                frameIndex: ordinal,
                presentationTime: presentationTime,
                duration: duration
            )
        )
        finalCheckpoint = try await prepared.makeTemporalCheckpoint(
            planSHA256: planSHA,
            lastCompletedInputOrdinal: Int64(ordinal)
        )
        let checkpoint = try ASHPreparedTemporalCheckpointV4.decodeCanonical(
            finalCheckpoint,
            expectedPlanSHA256: planSHA,
            expectedRuntimeManifestSHA256: runtime.manifestSHA256,
            expectedFormatIdentity: checkpointFormatIdentity(
                runtime: runtime,
                configuration: configuration
            )
        )
        guard try checkpoint.canonicalData == finalCheckpoint,
              let latest = checkpoint.history.frames.last else {
            throw ParityCaptureError.invalidFixture("noncanonical checkpoint")
        }
        let expectedOutputStart = definition.scanMode == "progressive"
            ? ordinal : ordinal * 2
        let classification = checkpoint.fieldCadenceState?
            .classification.rawValue
        let semantics = try outputs.enumerated().map { index, output in
            let priorGeneration = index == 0
                ? nil : outputs[index - 1].temporalGeneration
            let isFinalOutput = index == outputs.count - 1
            guard output.temporalGeneration > 0,
                  output.temporalGeneration <= checkpoint.history.generation,
                  (!isFinalOutput
                    || output.temporalGeneration
                        == checkpoint.history.generation),
                  priorGeneration.map({
                    output.temporalGeneration >= $0
                        && output.temporalGeneration - $0 <= 1
                  }) ?? true,
                  output.cadenceID == latest.cadenceID else {
                throw ParityCaptureError.invalidFixture(
                    "typed output semantics differ from checkpoint " +
                    "case=\(definition.id) backend=\(backend.rawValue) " +
                    "input=\(ordinal) output=\(index) " +
                    "outputGeneration=\(output.temporalGeneration) " +
                    "checkpointGeneration=\(checkpoint.history.generation) " +
                    "outputCadence=\(output.cadenceID) " +
                    "checkpointCadence=\(latest.cadenceID)"
                )
            }
            return ParitySemanticOutput(
                outputOrdinal: expectedOutputStart + index,
                presentationTime: try ParityTimeRecord(output.presentationTime),
                duration: try ParityTimeRecord(output.duration),
                sourceField: output.sourceField.rawValue,
                cadenceID: output.cadenceID,
                classification: classification,
                historyGeneration: output.temporalGeneration,
                attachments: try frameAttachments(output.pixelBuffer.value)
            )
        }
        semanticInputs.append(ParitySemanticInput(
            inputOrdinal: ordinal,
            timing: ParityInputTiming(
                presentationTime: try ParityTimeRecord(presentationTime),
                duration: try ParityTimeRecord(duration)
            ),
            effectiveDominance: effectiveDominance(frame.fieldDetail),
            sourceAttachments: sourceAttachments,
            outputs: semantics
        ))
        checkpointEntries.append(ParityCheckpointEntry(
            inputOrdinal: ordinal,
            canonicalDataBase64: finalCheckpoint.base64EncodedString(),
            canonicalSHA256: sha256(finalCheckpoint)
        ))
        buffers.append(contentsOf: outputs.map(\.pixelBuffer.value))
        sourcePaddingByteCount = max(
            sourcePaddingByteCount,
            try paddingByteCount(source, storage: configuration.storage)
        )
        let sourcePaddingAfter = try paddingBytes(
            source,
            storage: configuration.storage
        )
        paddingPreserved = paddingPreserved
            && sourcePaddingBefore == sourcePaddingAfter
        for destination in destinations {
            destinationPaddingByteCount = max(
                destinationPaddingByteCount,
                try paddingByteCount(
                    destination.value,
                    storage: configuration.storage
                )
            )
            let destinationPadding = try paddingBytes(
                destination.value,
                storage: configuration.storage
            )
            paddingPreserved = paddingPreserved
                && destinationPadding.allSatisfy { $0 == 0xD3 }
        }
    }
    guard !finalCheckpoint.isEmpty else {
        throw ParityCaptureError.invalidFixture("empty checkpoint range")
    }
    return ParityProcessedPixelRange(
        outputs: buffers,
        inputs: semanticInputs,
        checkpoints: checkpointEntries,
        finalCheckpoint: finalCheckpoint,
        sourcePaddingByteCount: sourcePaddingByteCount,
        destinationPaddingByteCount: destinationPaddingByteCount,
        paddingSentinelPreserved: paddingPreserved
    )
}

private func effectiveDominance(_ detail: String) -> String? {
    switch detail {
    case "temporal_top_first": "top_field_first"
    case "temporal_bottom_first": "bottom_field_first"
    default: nil
    }
}

private func executeAlpha(
    _ definition: ParityCaseDefinition,
    backend: FixedPointExecutionBackendV4,
    schedule: FixedPointExecutionScheduleV4,
    runtime: ASHVerifiedRuntimeBundleV4
) async throws -> ParityRunBytes {
    let layout = try alphaLayout(definition.storage)
    let association = try alphaAssociation(definition.association)
    let frame = definition.frames[0]
    let source = try makePackedBuffer(
        layout: layout,
        width: definition.sourceWidth,
        height: definition.sourceHeight,
        padding: 13,
        sentinel: 0xA7
    )
    let destination = try makePackedBuffer(
        layout: layout,
        width: definition.targetWidth,
        height: definition.targetHeight,
        padding: 17,
        sentinel: 0xD3
    )
    try Alpha4444PixelBufferAccessV4.write(
        alphaSamples(
            width: definition.sourceWidth,
            height: definition.sourceHeight,
            maximum: layout.signalBitDepth == 8 ? 255 : 65_535,
            association: association
        ),
        to: source,
        layout: layout
    )
    installAlphaAssociation(association, on: source)
    installNestedAttachment(on: source)
    let sourceAttachments = try frameAttachments(source)
    let sourcePaddingBefore = try packedPaddingBytes(source, layout: layout)
    let device = backend == .metal ? MTLCreateSystemDefaultDevice() : nil
    let library = try device.map {
        try ASHP06MetalLibraryFactoryV4.makeLibrary(
            runtime: runtime,
            device: $0
        )
    }
    let scaler = try Alpha4444FixedPointScalerV4(
        backend: backend == .cpu ? .cpu : .metal,
        layout: layout,
        sourceAssociation: association,
        destinationAssociation: association,
        zeroAlphaPolicy: .clearColor,
        sourceWidth: definition.sourceWidth,
        sourceHeight: definition.sourceHeight,
        targetWidth: definition.targetWidth,
        targetHeight: definition.targetHeight,
        borderRule: .reflect101,
        executionSchedule: schedule,
        metalDevice: device,
        metalLibrary: library
    )
    try await scaler.process(source: source, destination: destination)
    let presentation = CMTime(
        value: frame.presentationTime.value,
        timescale: frame.presentationTime.timescale
    )
    let duration = CMTime(
        value: frame.duration.value,
        timescale: frame.duration.timescale
    )
    let semantics = try canonicalJSON(ParitySemanticsDocument(
        caseID: definition.id,
        inputs: [ParitySemanticInput(
            inputOrdinal: 0,
            timing: ParityInputTiming(
                presentationTime: try ParityTimeRecord(presentation),
                duration: try ParityTimeRecord(duration)
            ),
            effectiveDominance: nil,
            sourceAttachments: sourceAttachments,
            outputs: [ParitySemanticOutput(
                outputOrdinal: 0,
                presentationTime: try ParityTimeRecord(presentation),
                duration: try ParityTimeRecord(duration),
                sourceField: "progressive",
                cadenceID: "progressive",
                classification: nil,
                historyGeneration: 1,
                attachments: try frameAttachments(destination)
            )]
        )]
    ))
    let checkpoints = try canonicalJSON(ParityCheckpointSet(
        caseID: definition.id,
        entries: []
    ))
    let resume = try canonicalJSON(ParityResumeSet(
        caseID: definition.id,
        entries: []
    ))
    let sourcePadding = try packedPaddingBytes(source, layout: layout)
    let destinationPadding = try packedPaddingBytes(destination, layout: layout)
    return ParityRunBytes(
        visible: try visiblePackedSequence([destination], layout: layout),
        semantics: semantics,
        checkpoints: checkpoints,
        resume: resume,
        sourcePaddingByteCount: sourcePadding.count,
        destinationPaddingByteCount: destinationPadding.count,
        paddingSentinelPreserved: sourcePadding == sourcePaddingBefore
            && destinationPadding.allSatisfy { $0 == 0xD3 }
    )
}

private func loadRuntime(mode: String) throws -> ASHVerifiedRuntimeBundleV4 {
    switch mode {
    case "production":
        guard ASHProductionP06TrustRootV4.isConfigured else {
            throw ParityCaptureError.invalidFixture(
                "the production P06 trust root is not configured"
            )
        }
        return try ASHP06RuntimeProviderV4.production(bundle: .main).load()
    case "fixture":
        return try ASHV4SemanticArtifactTestSupport
            .executableSystemMetalRuntime()
    default:
        throw ParityCaptureError.invalidEnvironment(
            "unknown runtime mode \(mode)"
        )
    }
}

private func makeRuntimeRecord(
    _ runtime: ASHVerifiedRuntimeBundleV4,
    mode: String,
    expected: ParityReleaseRuntimeContract
) throws -> ParityRuntimeRecord {
    let manifestBytes: Data
    if mode == "production" {
        manifestBytes = try Data(contentsOf: runtime.bundleURL
            .appendingPathComponent(ASHRuntimeManifestV4.fileName))
    } else {
        manifestBytes = try ASHCanonicalJSONV4.encode(runtime.manifest)
    }
    guard runtime.manifest.runtimeID == expected.runtimeID else {
        throw ParityCaptureError.invalidFixture("runtime identity mismatch")
    }
    if mode == "production" {
        guard runtime.manifest.releaseStatus.rawValue
                == expected.requiredReleaseStatus,
              runtime.bundleURL.lastPathComponent == "ASH-P06.bundle",
              ASHProductionP06TrustRootV4.manifestSHA256
                == runtime.manifestSHA256,
              ASHProductionP06TrustRootV4.sourceRevision
                == runtime.manifest.provenance.sourceRevision,
              ASHProductionP06TrustRootV4.builderSourceSHA256
                == runtime.manifest.provenance.builderSourceSHA256 else {
            throw ParityCaptureError.invalidFixture(
                "production runtime is not bound to its code trust root"
            )
        }
    }
    return ParityRuntimeRecord(
        mode: mode,
        runtimeID: runtime.manifest.runtimeID,
        releaseStatus: runtime.manifest.releaseStatus.rawValue,
        manifestSHA256: runtime.manifestSHA256.rawValue,
        manifestFileSHA256: sha256(manifestBytes),
        sourceRevision: runtime.manifest.provenance.sourceRevision,
        builderSourceSHA256:
            runtime.manifest.provenance.builderSourceSHA256.rawValue,
        trustRootConfigured: mode == "production"
            ? ASHProductionP06TrustRootV4.isConfigured : false,
        bindingVerified: true
    )
}

private func pixelStorage(_ value: String) throws -> PixelStorageV4 {
    switch value {
    case "nv12_video_range_8": .nv12VideoRange8Bit
    case "nv12_full_range_8": .nv12FullRange8Bit
    case "p010_video_range_10": .p010VideoRange10Bit
    case "p010_full_range_10": .p010FullRange10Bit
    default:
        throw ParityCaptureError.invalidContract("unsupported storage \(value)")
    }
}

private func alphaLayout(
    _ value: String
) throws -> Alpha4444PackedLayoutV4 {
    switch value {
    case "bgra8": .bgra8
    case "argb16_big_endian": .argb16BigEndian
    default:
        throw ParityCaptureError.invalidContract("unsupported alpha layout")
    }
}

private func alphaAssociation(_ value: String) throws -> AlphaAssociationV4 {
    switch value {
    case "straight": .straight
    case "premultiplied": .premultiplied
    default:
        throw ParityCaptureError.invalidContract("unsupported association")
    }
}

private func makePixelBuffer(
    storage: PixelStorageV4,
    width: Int,
    height: Int,
    metalCompatible: Bool
) throws -> CVPixelBuffer {
    try PixelBufferSignalCodecV4.makeBuffer(
        storage: storage,
        width: width,
        height: height,
        metalCompatible: metalCompatible
    )
}

private func makeSignalFrame(
    storage: PixelStorageV4,
    width: Int,
    height: Int,
    frame: ParityFrameDefinition
) -> PixelBufferSignalFrameV4 {
    let layout = PixelLayoutV4(storage: storage)
    let planes = layout.planes.enumerated().map { planeIndex, plane in
        let planeWidth = try! plane.width(forFrameWidth: width)
        let planeHeight = try! plane.height(forFrameHeight: height)
        var samples: [UInt16] = []
        samples.reserveCapacity(
            planeWidth * planeHeight * plane.componentsPerElement
        )
        for y in 0..<planeHeight {
            for x in 0..<planeWidth {
                for component in 0..<plane.componentsPerElement {
                    samples.append(patternValue(
                        frame: frame,
                        x: x,
                        y: y,
                        width: planeWidth,
                        plane: planeIndex,
                        component: component,
                        bounds: plane.signalCodeBounds[component]
                    ))
                }
            }
        }
        return try! PixelBufferSignalPlaneV4(
            width: planeWidth,
            height: planeHeight,
            componentsPerElement: plane.componentsPerElement,
            componentBounds: plane.signalCodeBounds,
            samples: samples
        )
    }
    return PixelBufferSignalFrameV4(
        storage: storage,
        width: width,
        height: height,
        planes: planes
    )
}

private func patternValue(
    frame: ParityFrameDefinition,
    x: Int,
    y: Int,
    width: Int,
    plane: Int,
    component: Int,
    bounds: PixelCodeBoundsV4
) -> UInt16 {
    let low = Int(bounds.minimum)
    let high = Int(bounds.maximum)
    let span = max(1, high - low)
    let value: Int
    switch frame.pattern {
    case "moving_edge_0", "moving_edge_1", "moving_edge_2":
        let shift = ["moving_edge_0": 0, "moving_edge_1": 1][frame.pattern]
            ?? 2
        let edge = max(1, width / 2 + shift)
        let base = x < edge ? low + span / 6 : high - span / 7
        value = base + ((y * 7 + component * 11 + plane * 13)
            % max(1, span / 10))
    case "scene_cut_white":
        value = high - ((x + y + component) % max(1, span / 32))
    case "rational_detail":
        value = low + ((x * 97 + y * 53 + component * 29 + plane * 71)
            % (span + 1))
    case "field_pair":
        let token = y.isMultiple(of: 2)
            ? (frame.topToken ?? 0) : (frame.bottomToken ?? 0)
        value = low + ((token * 977 + x * 31 + component * 19 + plane * 43)
            % (span + 1))
    default:
        value = low + span / 2
    }
    return UInt16(min(high, max(low, value)))
}

private func installPixelAttachments(
    on buffer: CVPixelBuffer,
    storage: PixelStorageV4,
    frame: ParityFrameDefinition
) throws {
    let hdr = frame.hdrProfile != "none"
    CVBufferSetAttachment(
        buffer,
        kCVImageBufferColorPrimariesKey,
        hdr ? kCVImageBufferColorPrimaries_ITU_R_2020
            : kCVImageBufferColorPrimaries_ITU_R_709_2,
        .shouldPropagate
    )
    let transfer: CFString
    switch frame.hdrProfile {
    case "hlg_static_dynamic":
        transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
    case "pq_static", "pq_static_dynamic":
        transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
    default:
        transfer = kCVImageBufferTransferFunction_ITU_R_709_2
    }
    CVBufferSetAttachment(
        buffer,
        kCVImageBufferTransferFunctionKey,
        transfer,
        .shouldPropagate
    )
    CVBufferSetAttachment(
        buffer,
        kCVImageBufferYCbCrMatrixKey,
        hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020
            : kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        .shouldPropagate
    )
    CVBufferSetAttachment(
        buffer,
        kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferChromaLocation_Left,
        .shouldPropagate
    )
    if frame.fieldDetail != "none" {
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferChromaLocation_Center,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferFieldCountKey,
            NSNumber(value: 2),
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferFieldDetailKey,
            frame.fieldDetail == "temporal_top_first"
                ? kCVImageBufferFieldDetailTemporalTopFirst
                : kCVImageBufferFieldDetailTemporalBottomFirst,
            .shouldPropagate
        )
    }
    if hdr {
        let metadata = try parityStaticHDRMetadata()
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            metadata.masteringDisplayColorVolume!.payload as CFData,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferContentLightLevelInfoKey,
            metadata.contentLightLevelInfo!.payload as CFData,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferAmbientViewingEnvironmentKey,
            metadata.ambientViewingEnvironment!.payload as CFData,
            .shouldPropagate
        )
    }
    if frame.hdrProfile.hasSuffix("_dynamic") {
        CVBufferSetAttachment(
            buffer,
            kCMSampleAttachmentKey_HDR10PlusPerFrameData,
            Data([0xB5, 0x00, 0x3C, 0x00, 0x01]) as CFData,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCMSampleAttachmentKey_PostDecodeProcessingMetadata,
            ["mode": "fixture", "strength": 7] as CFDictionary,
            .shouldPropagate
        )
    }
    installNestedAttachment(on: buffer)
    _ = storage
}

private func parityStaticHDRMetadata() throws -> HDRStaticMetadataV4 {
    let primaries = [
        try HDRChromaticityV4(x: 8_500, y: 39_850, label: "green"),
        try HDRChromaticityV4(x: 6_550, y: 2_300, label: "blue"),
        try HDRChromaticityV4(x: 35_400, y: 14_600, label: "red")
    ]
    return HDRStaticMetadataV4(
        masteringDisplayColorVolume: try MasteringDisplayColorVolumeV4(
            displayPrimaries: primaries,
            whitePoint: HDRChromaticityV4(
                x: 15_635,
                y: 16_450,
                label: "white"
            ),
            maximumDisplayMasteringLuminance: 10_000_000,
            minimumDisplayMasteringLuminance: 50
        ),
        contentLightLevelInfo: try ContentLightLevelInfoV4(
            maximumContentLightLevel: 1_000,
            maximumFrameAverageLightLevel: 400
        ),
        ambientViewingEnvironment: AmbientViewingEnvironmentV4(
            ambientIlluminance: 123_456,
            ambientLight: try HDRChromaticityV4(
                x: 15_635,
                y: 16_450,
                label: "ambient"
            )
        )
    )
}

private func installNestedAttachment(on buffer: CVPixelBuffer) {
    let nested: NSDictionary = [
        "array": [true, NSNumber(value: 7)],
        "blob": Data("ash".utf8),
        "date": Date(timeIntervalSince1970: 1_700_000_000)
    ]
    CVBufferSetAttachment(
        buffer,
        "MirmirParityNested" as CFString,
        nested,
        .shouldPropagate
    )
}

private func checkpointFormatIdentity(
    runtime: ASHVerifiedRuntimeBundleV4,
    configuration: DeterministicPreparedConfigurationV4
) -> ASHSHA256V4 {
    ASHSHA256V4(rawData: Data(
        [
            ASHRuntimeManifestV4.runtimeIdentity,
            runtime.manifestSHA256.rawValue,
            configuration.storage.rawValue,
            String(configuration.sourceWidth),
            String(configuration.sourceHeight),
            String(configuration.targetWidth),
            String(configuration.targetHeight),
            configuration.scaleRouteIdentity
        ].joined(separator: "|").utf8
    ))
}

private func alphaSamples(
    width: Int,
    height: Int,
    maximum: UInt16,
    association: AlphaAssociationV4
) -> [AlphaSampleV4] {
    let scale = Int(maximum)
    var samples: [AlphaSampleV4] = []
    samples.reserveCapacity(width * height)
    for index in 0..<(width * height) {
        let x = index % width
        let y = index / width
        let alpha = (x + y).isMultiple(of: 4)
            ? 0
            : UInt16((x * 17_003 + y * 11_111 + scale / 3) % (scale + 1))
        let straight = AlphaSampleV4(
            red: UInt16((x * 9_973 + y * 2_003 + 101) % (scale + 1)),
            green: UInt16((x * 4_099 + y * 7_919 + 211) % (scale + 1)),
            blue: UInt16((x * 2_057 + y * 13_007 + 307) % (scale + 1)),
            alpha: alpha
        )
        guard association == .premultiplied, alpha > 0 else {
            samples.append(alpha == 0
                ? AlphaSampleV4(red: 0, green: 0, blue: 0, alpha: 0)
                : straight)
            continue
        }
        func premultiply(_ value: UInt16) -> UInt16 {
            UInt16((UInt64(value) * UInt64(alpha) + UInt64(maximum / 2))
                / UInt64(maximum))
        }
        samples.append(AlphaSampleV4(
            red: premultiply(straight.red),
            green: premultiply(straight.green),
            blue: premultiply(straight.blue),
            alpha: alpha
        ))
    }
    return samples
}

private func makePackedBuffer(
    layout: Alpha4444PackedLayoutV4,
    width: Int,
    height: Int,
    padding: Int,
    sentinel: UInt8
) throws -> CVPixelBuffer {
    let rowBytes = width * layout.bytesPerPixel + padding
    let byteCount = rowBytes * height
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: byteCount,
        alignment: 64
    )
    storage.initializeMemory(as: UInt8.self, repeating: sentinel, count: byteCount)
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(
        kCFAllocatorDefault,
        width,
        height,
        layout.pixelFormat,
        storage,
        rowBytes,
        { _, base in base?.deallocate() },
        nil,
        nil,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        storage.deallocate()
        throw ParityCaptureError.invalidFixture("packed buffer creation failed")
    }
    return buffer
}

private func installAlphaAssociation(
    _ association: AlphaAssociationV4,
    on buffer: CVPixelBuffer
) {
    CVBufferSetAttachment(
        buffer,
        kCVImageBufferAlphaChannelModeKey,
        association == .straight
            ? kCVImageBufferAlphaChannelMode_StraightAlpha
            : kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
        .shouldPropagate
    )
}

private func visiblePixelSequence(
    _ buffers: [CVPixelBuffer],
    storage: PixelStorageV4
) throws -> Data {
    var result = Data()
    appendUInt32(UInt32(buffers.count), to: &result)
    for buffer in buffers {
        result.append(try visiblePixelFrame(buffer, storage: storage))
    }
    return result
}

private func visiblePixelFrame(
    _ buffer: CVPixelBuffer,
    storage: PixelStorageV4
) throws -> Data {
    let layout = PixelLayoutV4(storage: storage)
    try layout.validateStructure(of: buffer)
    let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
    guard status == kCVReturnSuccess else {
        throw ParityCaptureError.invalidFixture("pixel buffer lock failed")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    var result = Data()
    appendUInt32(UInt32(CVPixelBufferGetWidth(buffer)), to: &result)
    appendUInt32(UInt32(CVPixelBufferGetHeight(buffer)), to: &result)
    appendUInt32(UInt32(layout.planes.count), to: &result)
    for (planeIndex, plane) in layout.planes.enumerated() {
        let width = CVPixelBufferGetWidthOfPlane(buffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(buffer, planeIndex)
        let elementBytes = plane.componentsPerElement * plane.bytesPerComponent
        let bytes = try activePlaneBytes(
            base: CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex),
            rowStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex),
            activeRowBytes: width * elementBytes,
            height: height
        )
        appendUInt32(UInt32(width), to: &result)
        appendUInt32(UInt32(height), to: &result)
        appendUInt32(UInt32(elementBytes), to: &result)
        appendUInt32(UInt32(bytes.count), to: &result)
        result.append(bytes)
    }
    return result
}

private func visiblePackedSequence(
    _ buffers: [CVPixelBuffer],
    layout: Alpha4444PackedLayoutV4
) throws -> Data {
    var result = Data()
    appendUInt32(UInt32(buffers.count), to: &result)
    for buffer in buffers {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw ParityCaptureError.invalidFixture("packed buffer lock failed")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytes = try activePlaneBytes(
            base: CVPixelBufferGetBaseAddress(buffer),
            rowStride: CVPixelBufferGetBytesPerRow(buffer),
            activeRowBytes: width * layout.bytesPerPixel,
            height: height
        )
        appendUInt32(UInt32(width), to: &result)
        appendUInt32(UInt32(height), to: &result)
        appendUInt32(1, to: &result)
        appendUInt32(UInt32(width), to: &result)
        appendUInt32(UInt32(height), to: &result)
        appendUInt32(UInt32(layout.bytesPerPixel), to: &result)
        appendUInt32(UInt32(bytes.count), to: &result)
        result.append(bytes)
    }
    return result
}

private func activePlaneBytes(
    base: UnsafeMutableRawPointer?,
    rowStride: Int,
    activeRowBytes: Int,
    height: Int
) throws -> Data {
    guard let base, rowStride >= activeRowBytes else {
        throw ParityCaptureError.invalidFixture("invalid visible plane")
    }
    var result = Data(capacity: activeRowBytes * height)
    for y in 0..<height {
        result.append(
            base.advanced(by: y * rowStride)
                .assumingMemoryBound(to: UInt8.self),
            count: activeRowBytes
        )
    }
    return result
}

private func frameAttachments(
    _ buffer: CVPixelBuffer
) throws -> [ParityAttachmentValue] {
    var result: [ParityAttachmentValue] = []
    for (mode, name) in [
        (CVAttachmentMode.shouldPropagate, "should_propagate"),
        (.shouldNotPropagate, "should_not_propagate")
    ] {
        guard let raw = CVBufferCopyAttachments(buffer, mode) else { continue }
        let dictionary = raw as NSDictionary
        for (key, value) in dictionary {
            guard let key = key as? String else {
                throw ParityCaptureError.invalidFixture(
                    "attachment dictionary contains a non-string key"
                )
            }
            result.append(ParityAttachmentValue(
                key: key,
                mode: name,
                value: try canonicalAttachmentValue(value)
            ))
        }
    }
    let sorted = result.sorted { $0.key < $1.key }
    guard Set(sorted.map(\.key)).count == sorted.count else {
        throw ParityCaptureError.invalidFixture("duplicate attachment key")
    }
    return sorted
}

private func canonicalAttachmentValue(
    _ value: Any
) throws -> ParityAttachmentPayload {
    if value is NSNull { return .null }
    let object = value as AnyObject
    let typeID = CFGetTypeID(object)
    if typeID == CFBooleanGetTypeID() {
        return .boolean((value as! NSNumber).boolValue)
    }
    if typeID == CFStringGetTypeID() {
        return .string(value as! String)
    }
    if typeID == CFDataGetTypeID() {
        return .data((value as! Data).base64EncodedString())
    }
    if typeID == CFDateGetTypeID() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return .date(formatter.string(from: value as! Date))
    }
    if typeID == CFNumberGetTypeID() {
        let number = value as! NSNumber
        switch CFNumberGetType(number) {
        case .float32Type, .float64Type, .floatType, .doubleType,
             .cgFloatType:
            return .realBits(String(
                format: "%016llx",
                number.doubleValue.bitPattern
            ))
        default:
            let unsignedTokens = "CISLQ"
            let token = String(cString: number.objCType)
            if unsignedTokens.contains(token) {
                return .unsignedInteger(String(number.uint64Value))
            }
            return .signedInteger(String(number.int64Value))
        }
    }
    if let array = value as? [Any] {
        return .array(try array.map(canonicalAttachmentValue))
    }
    if let dictionary = value as? NSDictionary {
        var entries: [ParityAttachmentDictionaryEntry] = []
        for (key, nested) in dictionary {
            guard let key = key as? String else {
                throw ParityCaptureError.invalidFixture(
                    "nested attachment dictionary has a non-string key"
                )
            }
            entries.append(ParityAttachmentDictionaryEntry(
                key: key,
                value: try canonicalAttachmentValue(nested)
            ))
        }
        return .dictionary(entries.sorted { $0.key < $1.key })
    }
    throw ParityCaptureError.invalidFixture(
        "unsupported attachment value \(type(of: value))"
    )
}

private func fillAllStorageBytes(
    _ buffer: CVPixelBuffer,
    sentinel: UInt8
) throws {
    let status = CVPixelBufferLockBaseAddress(buffer, [])
    guard status == kCVReturnSuccess else {
        throw ParityCaptureError.invalidFixture("pixel buffer lock failed")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
            throw ParityCaptureError.invalidFixture("missing plane")
        }
        memset(
            base,
            Int32(sentinel),
            CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                * CVPixelBufferGetHeightOfPlane(buffer, plane)
        )
    }
}

private func paddingByteCount(
    _ buffer: CVPixelBuffer,
    storage: PixelStorageV4
) throws -> Int {
    let layout = PixelLayoutV4(storage: storage)
    return try layout.planes.indices.reduce(0) { total, planeIndex in
        let plane = layout.planes[planeIndex]
        let active = CVPixelBufferGetWidthOfPlane(buffer, planeIndex)
            * plane.componentsPerElement * plane.bytesPerComponent
        let padding = CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
            - active
        guard padding >= 0 else {
            throw ParityCaptureError.invalidFixture("invalid plane stride")
        }
        return total + padding
            * CVPixelBufferGetHeightOfPlane(buffer, planeIndex)
    }
}

private func paddingBytes(
    _ buffer: CVPixelBuffer,
    storage: PixelStorageV4
) throws -> [UInt8] {
    let layout = PixelLayoutV4(storage: storage)
    let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
    guard status == kCVReturnSuccess else {
        throw ParityCaptureError.invalidFixture("pixel buffer lock failed")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    var result: [UInt8] = []
    for planeIndex in layout.planes.indices {
        let plane = layout.planes[planeIndex]
        let active = CVPixelBufferGetWidthOfPlane(buffer, planeIndex)
            * plane.componentsPerElement * plane.bytesPerComponent
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex),
              stride >= active else {
            throw ParityCaptureError.invalidFixture("invalid plane")
        }
        for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, planeIndex) {
            let row = base.advanced(by: y * stride)
                .assumingMemoryBound(to: UInt8.self)
            result.append(contentsOf: UnsafeBufferPointer(
                start: row.advanced(by: active),
                count: stride - active
            ))
        }
    }
    return result
}

private func packedPaddingBytes(
    _ buffer: CVPixelBuffer,
    layout: Alpha4444PackedLayoutV4
) throws -> [UInt8] {
    let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
    guard status == kCVReturnSuccess,
          let base = CVPixelBufferGetBaseAddress(buffer) else {
        throw ParityCaptureError.invalidFixture("packed buffer lock failed")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let active = CVPixelBufferGetWidth(buffer) * layout.bytesPerPixel
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    var result: [UInt8] = []
    for y in 0..<CVPixelBufferGetHeight(buffer) {
        let row = base.advanced(by: y * stride)
            .assumingMemoryBound(to: UInt8.self)
        result.append(contentsOf: UnsafeBufferPointer(
            start: row.advanced(by: active),
            count: stride - active
        ))
    }
    return result
}

private func makeArtifactManifest(
    root: URL,
    excluding: Set<String>
) throws -> ParityArtifactManifest {
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw ParityCaptureError.invalidOutput("cannot enumerate artifacts")
    }
    var artifacts: [ParityArtifact] = []
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        if values.isSymbolicLink == true {
            throw ParityCaptureError.invalidOutput("symbolic link in capture")
        }
        guard values.isRegularFile == true else { continue }
        let relative = relativePath(url, to: root)
        if excluding.contains(relative) { continue }
        artifacts.append(try artifact(url, relativeTo: root))
    }
    return ParityArtifactManifest(
        schemaVersion: "mirmir-ash-v4-cpu-metal-parity-artifacts-v2",
        artifacts: artifacts.sorted { $0.path < $1.path }
    )
}

private func artifact(
    _ url: URL,
    relativeTo root: URL
) throws -> ParityArtifact {
    let data = try Data(contentsOf: url)
    return ParityArtifact(
        path: relativePath(url, to: root),
        byteCount: data.count,
        sha256: sha256(data)
    )
}

private func relativePath(_ url: URL, to root: URL) -> String {
    String(url.standardizedFileURL.path
        .dropFirst(root.standardizedFileURL.path.count + 1))
}

private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    return data
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func isSHA256(_ value: String) -> Bool {
    value.count == 64
        && value == value.lowercased()
        && value.allSatisfy { $0.isHexDigit }
}

private func requiredEnvironment(
    _ key: String,
    in environment: [String: String]
) throws -> String {
    guard let value = environment[key], !value.isEmpty else {
        throw ParityCaptureError.invalidEnvironment("missing \(key)")
    }
    return value
}

private func createNewDirectory(_ url: URL) throws {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        let contents = try manager.contentsOfDirectory(atPath: url.path)
        guard isDirectory.boolValue, contents.isEmpty else {
            throw ParityCaptureError.invalidOutput(
                "refusing to overwrite nonempty \(url.path)"
            )
        }
    } else {
        try manager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}
