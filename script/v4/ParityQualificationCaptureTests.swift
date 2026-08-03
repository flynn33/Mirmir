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
                "Set MIRMIR_PARITY_CAPTURE_DIRECTORY to run the locked parity capture."
            )
        }
        let contractPath = try requiredEnvironment(
            "MIRMIR_PARITY_CONTRACT_PATH",
            in: environment
        )
        let contractData = try Data(contentsOf: URL(fileURLWithPath: contractPath))
        let contract = try JSONDecoder().decode(
            ParityCaptureContract.self,
            from: contractData
        )
        try contract.validate()

        let contractSHA256 = sha256(contractData)
        XCTAssertEqual(
            contractSHA256,
            try requiredEnvironment("MIRMIR_PARITY_CONTRACT_SHA256", in: environment)
        )
        XCTAssertEqual(
            contract.tools.captureSourceSHA256,
            try requiredEnvironment("MIRMIR_PARITY_CAPTURE_SOURCE_SHA256", in: environment)
        )

        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try createNewDirectory(output)
        let runtimeMode = environment["MIRMIR_PARITY_RUNTIME_MODE"] ?? "production"
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

        var capturedCases: [ParityCapturedCase] = []
        for definition in contract.cases {
            let directory = output
                .appendingPathComponent("cases", isDirectory: true)
                .appendingPathComponent(definition.id, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            capturedCases.append(
                try await capture(
                    definition,
                    contract: contract,
                    runtime: runtime,
                    outputRoot: output,
                    caseDirectory: directory
                )
            )
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
            cases: capturedCases.sorted { $0.id < $1.id }
        )
        let captureURL = output.appendingPathComponent("capture.json")
        try canonicalJSON(capture).write(to: captureURL, options: .atomic)
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
        case .invalidContract(let detail): "invalid parity contract: \(detail)"
        case .invalidEnvironment(let detail): "invalid capture environment: \(detail)"
        case .invalidOutput(let detail): "invalid parity output: \(detail)"
        case .invalidFixture(let detail): "invalid parity fixture: \(detail)"
        case .parityFailure(let detail): "CPU/Metal parity failure: \(detail)"
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
    let comparison: String
    let repeatExecutionCount: Int
    let crossProcessCaptureCount: Int
    let tileSchedules: [String]
    let parityCoverage: [String]
    let releaseRuntime: ParityReleaseRuntimeContract
    let tools: ParityToolIdentities
    let cases: [ParityCaseDefinition]

    func validate() throws {
        guard schemaVersion == "mirmir-ash-v4-cpu-metal-parity-contract-v1",
              gateID == "deterministic-engine-v4-cpu-metal-byte-parity",
              buildConfiguration == "Release",
              captureSchemaVersion
                == "mirmir-ash-v4-cpu-metal-parity-capture-v1",
              reportSchemaVersion
                == "mirmir-ash-v4-cpu-metal-parity-report-v1",
              comparison == "exact_visible_plane_and_attachment_bytes",
              repeatExecutionCount == 2,
              crossProcessCaptureCount == 2,
              tileSchedules == ["row_major", "reverse", "even_then_odd"],
              Set(parityCoverage).count == parityCoverage.count,
              Set(cases.map(\.id)).count == cases.count,
              !cases.isEmpty else {
            throw ParityCaptureError.invalidContract("header or count mismatch")
        }
        let covered = Set(cases.flatMap(\.coverage))
        guard covered == Set(parityCoverage) else {
            throw ParityCaptureError.invalidContract("coverage is not exact")
        }
        for value in [
            tools.captureSourceSHA256,
            tools.evaluatorSHA256,
            tools.runnerSHA256
        ] where !isSHA256(value) {
            throw ParityCaptureError.invalidContract("tool identity is not SHA-256")
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

private struct ParityCaseDefinition: Codable, Equatable {
    let id: String
    let kind: String
    let storage: String
    let association: String
    let sourceWidth: Int
    let sourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int
    let framePatterns: [String]
    let coverage: [String]

    func validate(allowedCoverage: Set<String>) throws {
        guard id.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression)
                != nil,
              ["pixel_spatial", "pixel_temporal", "alpha_spatial"].contains(kind),
              sourceWidth > 0,
              sourceHeight > 0,
              targetWidth >= sourceWidth,
              targetHeight >= sourceHeight,
              targetWidth > sourceWidth || targetHeight > sourceHeight,
              !framePatterns.isEmpty,
              !coverage.isEmpty,
              Set(coverage).count == coverage.count,
              Set(coverage).isSubset(of: allowedCoverage) else {
            throw ParityCaptureError.invalidContract("invalid case \(id)")
        }
        if kind == "pixel_temporal", framePatterns.count != 3 {
            throw ParityCaptureError.invalidContract(
                "temporal case \(id) requires three frames"
            )
        }
        if kind == "alpha_spatial", association == "none" {
            throw ParityCaptureError.invalidContract(
                "alpha case \(id) requires an association"
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

private struct ParityScheduleArtifact: Codable, Equatable {
    let schedule: String
    let artifact: ParityArtifact
}

private struct ParityBackendArtifacts: Codable, Equatable {
    let visible: ParityArtifact
    let attachments: ParityArtifact
    let repeatVisible: ParityArtifact
    let repeatAttachments: ParityArtifact
    let tileSchedules: [ParityScheduleArtifact]
}

private struct ParityCapturedCase: Codable, Equatable {
    let id: String
    let definition: ParityCaseDefinition
    let cpu: ParityBackendArtifacts
    let metal: ParityBackendArtifacts
    let metadata: ParityArtifact
    let repeatRunIdentityPass: Bool
    let withinProcessCPUAndMetalPass: Bool
    let tileScheduleIdentityPass: Bool
    let temporalHistoryExercised: Bool
    let temporalResetExercised: Bool
    let sceneCutExercised: Bool
    let stridePaddingAdversaryExercised: Bool
    let arbitraryRationalPhaseExercised: Bool
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
    let temporal: ParityTemporalEvidence?
}

private struct ParityTemporalEvidence: Codable, Equatable {
    let generations: [UInt64]
    let historyFrameCounts: [Int]
    let continuousFrameDiffersFromReset: Bool
    let sceneCutEqualsSpatialReset: Bool
    let checkpointsCanonical: Bool
}

private struct ParityAttachmentEnvelope: Codable, Equatable {
    let schemaVersion: String
    let frames: [ParityFrameAttachments]
    let temporalCheckpoints: [ParityCheckpointAttachment]
}

private struct ParityFrameAttachments: Codable, Equatable {
    let ordinal: Int
    let values: [ParityAttachmentValue]
}

private struct ParityAttachmentValue: Codable, Equatable {
    let key: String
    let mode: String
    let value: String
}

private struct ParityCheckpointAttachment: Codable, Equatable {
    let ordinal: Int
    let canonicalSHA256: String
    let canonicalByteCount: Int
    let generation: UInt64
    let historyFrameCount: Int
    let latestFrameOrdinal: Int64
}

private struct ParityExecutionResult {
    let visible: Data
    let attachments: Data
    let visibleBySchedule: [String: Data]
    let sourcePaddingByteCount: Int
    let destinationPaddingByteCount: Int
    let paddingSentinelPreserved: Bool
    let temporal: ParityTemporalEvidence?
}

private func capture(
    _ definition: ParityCaseDefinition,
    contract: ParityCaptureContract,
    runtime: ASHVerifiedRuntimeBundleV4,
    outputRoot: URL,
    caseDirectory: URL
) async throws -> ParityCapturedCase {
    let cpuFirst = try await execute(
        definition,
        backend: .cpu,
        runtime: runtime,
        tileSchedules: contract.tileSchedules
    )
    let cpuRepeat = try await execute(
        definition,
        backend: .cpu,
        runtime: runtime,
        tileSchedules: contract.tileSchedules
    )
    let metalFirst = try await execute(
        definition,
        backend: .metal,
        runtime: runtime,
        tileSchedules: contract.tileSchedules
    )
    let metalRepeat = try await execute(
        definition,
        backend: .metal,
        runtime: runtime,
        tileSchedules: contract.tileSchedules
    )

    let repeatPass = cpuFirst.visible == cpuRepeat.visible
        && cpuFirst.attachments == cpuRepeat.attachments
        && metalFirst.visible == metalRepeat.visible
        && metalFirst.attachments == metalRepeat.attachments
    let backendPass = cpuFirst.visible == metalFirst.visible
        && cpuFirst.attachments == metalFirst.attachments
    let tilePass = contract.tileSchedules.allSatisfy { schedule in
        cpuFirst.visibleBySchedule[schedule] == cpuFirst.visible
            && metalFirst.visibleBySchedule[schedule] == metalFirst.visible
            && cpuRepeat.visibleBySchedule[schedule] == cpuFirst.visible
            && metalRepeat.visibleBySchedule[schedule] == metalFirst.visible
    }
    guard repeatPass, backendPass, tilePass else {
        throw ParityCaptureError.parityFailure(definition.id)
    }

    let cpuArtifacts = try writeBackendArtifacts(
        name: "cpu",
        first: cpuFirst,
        repeatResult: cpuRepeat,
        schedules: contract.tileSchedules,
        outputRoot: outputRoot,
        directory: caseDirectory
    )
    let metalArtifacts = try writeBackendArtifacts(
        name: "metal",
        first: metalFirst,
        repeatResult: metalRepeat,
        schedules: contract.tileSchedules,
        outputRoot: outputRoot,
        directory: caseDirectory
    )

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
        cpuSourcePaddingByteCount: cpuFirst.sourcePaddingByteCount,
        cpuDestinationPaddingByteCount: cpuFirst.destinationPaddingByteCount,
        metalSourcePaddingByteCount: metalFirst.sourcePaddingByteCount,
        metalDestinationPaddingByteCount: metalFirst.destinationPaddingByteCount,
        cpuPaddingSentinelPreserved: cpuFirst.paddingSentinelPreserved,
        metalPaddingSentinelPreserved: metalFirst.paddingSentinelPreserved,
        temporal: cpuFirst.temporal
    )
    let metadataURL = caseDirectory.appendingPathComponent("case-metadata.json")
    try canonicalJSON(metadata).write(to: metadataURL, options: .atomic)
    let metadataArtifact = try artifact(metadataURL, relativeTo: outputRoot)
    let temporal = cpuFirst.temporal
    let temporalHistory = temporal?.continuousFrameDiffersFromReset ?? false
    let temporalReset = temporal.map {
        $0.generations.first == 1 && $0.checkpointsCanonical
    } ?? false
    let sceneCut = temporal.map {
        $0.generations.last == 2 && $0.historyFrameCounts.last == 1
            && $0.sceneCutEqualsSpatialReset
    } ?? false
    let padding = cpuFirst.sourcePaddingByteCount > 0
        && cpuFirst.destinationPaddingByteCount > 0
        && metalFirst.sourcePaddingByteCount > 0
        && metalFirst.destinationPaddingByteCount > 0
        && cpuFirst.paddingSentinelPreserved
        && metalFirst.paddingSentinelPreserved
    let rational = plan.horizontal.uniquePhases.count > 1
        && plan.vertical.uniquePhases.count > 1

    if definition.coverage.contains("temporal_history"), !temporalHistory {
        throw ParityCaptureError.invalidFixture(
            "\(definition.id) did not change a temporal output"
        )
    }
    if definition.coverage.contains("temporal_reset"), !temporalReset {
        throw ParityCaptureError.invalidFixture(
            "\(definition.id) did not prove temporal reset"
        )
    }
    if definition.coverage.contains("scene_cut"), !sceneCut {
        throw ParityCaptureError.invalidFixture(
            "\(definition.id) did not prove scene-cut fallback"
        )
    }
    if definition.coverage.contains("stride_padding_adversary"), !padding {
        throw ParityCaptureError.invalidFixture(
            "\(definition.id) did not exercise padding"
        )
    }
    if definition.coverage.contains("arbitrary_rational_phase"), !rational {
        throw ParityCaptureError.invalidFixture(
            "\(definition.id) did not exercise rational phases"
        )
    }

    return ParityCapturedCase(
        id: definition.id,
        definition: definition,
        cpu: cpuArtifacts,
        metal: metalArtifacts,
        metadata: metadataArtifact,
        repeatRunIdentityPass: repeatPass,
        withinProcessCPUAndMetalPass: backendPass,
        tileScheduleIdentityPass: tilePass,
        temporalHistoryExercised: temporalHistory,
        temporalResetExercised: temporalReset,
        sceneCutExercised: sceneCut,
        stridePaddingAdversaryExercised: padding,
        arbitraryRationalPhaseExercised: rational
    )
}

private func execute(
    _ definition: ParityCaseDefinition,
    backend: FixedPointExecutionBackendV4,
    runtime: ASHVerifiedRuntimeBundleV4,
    tileSchedules: [String]
) async throws -> ParityExecutionResult {
    switch definition.kind {
    case "pixel_spatial", "pixel_temporal":
        return try await executePixelCase(
            definition,
            backend: backend,
            runtime: runtime,
            tileSchedules: tileSchedules
        )
    case "alpha_spatial":
        return try await executeAlphaCase(
            definition,
            backend: backend,
            runtime: runtime,
            tileSchedules: tileSchedules
        )
    default:
        throw ParityCaptureError.invalidContract(
            "unknown case kind \(definition.kind)"
        )
    }
}

private func executePixelCase(
    _ definition: ParityCaseDefinition,
    backend: FixedPointExecutionBackendV4,
    runtime: ASHVerifiedRuntimeBundleV4,
    tileSchedules: [String]
) async throws -> ParityExecutionResult {
    let storage = try pixelStorage(definition.storage)
    let configuration = DeterministicPreparedConfigurationV4(
        backendID: backend == .cpu
            ? .mirmirDeterministicCPU : .mirmirDeterministicMetal,
        executionBackend: backend,
        storage: storage,
        sourceWidth: definition.sourceWidth,
        sourceHeight: definition.sourceHeight,
        targetWidth: definition.targetWidth,
        targetHeight: definition.targetHeight,
        scanMode: .progressive
    )
    let device = backend == .metal ? MTLCreateSystemDefaultDevice() : nil
    let library = try device.map {
        try ASHP06MetalLibraryFactoryV4.makeLibrary(runtime: runtime, device: $0)
    }
    let prepared = try PreparedDeterministicV4Upscaler(
        configuration: configuration,
        runtime: runtime,
        metalDevice: device,
        metalLibrary: library
    )
    var outputs: [CVPixelBuffer] = []
    var sourcePadding = 0
    var destinationPadding = 0
    var paddingSentinelsPreserved = true
    var checkpoints: [ParityCheckpointAttachment] = []
    let planSHA = ASHSHA256V4(rawData: Data("parity:\(definition.id)".utf8))

    for (ordinal, pattern) in definition.framePatterns.enumerated() {
        let source = try makePixelBuffer(
            storage: storage,
            width: definition.sourceWidth,
            height: definition.sourceHeight,
            metalCompatible: backend == .metal
        )
        try fillAllStorageBytes(source, sentinel: 0xA7)
        try PixelBufferSignalCodecV4.write(
            makeSignalFrame(
                storage: storage,
                width: definition.sourceWidth,
                height: definition.sourceHeight,
                pattern: pattern
            ),
            to: source
        )
        installColorAttachments(on: source, storage: storage)
        let sourcePaddingBeforeProcess = try paddingBytes(
            source,
            storage: storage
        )
        let destination = try makePixelBuffer(
            storage: storage,
            width: definition.targetWidth,
            height: definition.targetHeight,
            metalCompatible: backend == .metal
        )
        try fillAllStorageBytes(destination, sentinel: 0xD3)
        sourcePadding = max(sourcePadding, try paddingByteCount(source, storage: storage))
        destinationPadding = max(
            destinationPadding,
            try paddingByteCount(destination, storage: storage)
        )
        try await prepared.process(
            source: FramePixelBuffer(source),
            destination: FramePixelBuffer(destination),
            timing: FrameTiming(
                frameIndex: ordinal,
                presentationTime: CMTime(value: Int64(ordinal), timescale: 30),
                duration: CMTime(value: 1, timescale: 30)
            )
        )
        let observedSourcePadding = try paddingBytes(source, storage: storage)
        let observedDestinationPadding = try paddingBytes(
            destination,
            storage: storage
        )
        paddingSentinelsPreserved = paddingSentinelsPreserved
            && observedSourcePadding == sourcePaddingBeforeProcess
            && observedDestinationPadding.allSatisfy { $0 == 0xD3 }
        outputs.append(destination)
        let checkpointData = try await prepared.makeTemporalCheckpoint(
            planSHA256: planSHA,
            lastCompletedInputOrdinal: Int64(ordinal)
        )
        let checkpoint = try ASHPreparedTemporalCheckpointV4.decodeCanonical(
            checkpointData,
            expectedPlanSHA256: planSHA,
            expectedRuntimeManifestSHA256: runtime.manifestSHA256,
            expectedFormatIdentity: checkpointFormatIdentity(
                runtime: runtime,
                configuration: configuration
            )
        )
        guard try checkpoint.canonicalData == checkpointData,
              let latest = checkpoint.history.frames.last else {
            throw ParityCaptureError.invalidFixture("noncanonical checkpoint")
        }
        checkpoints.append(ParityCheckpointAttachment(
            ordinal: ordinal,
            canonicalSHA256: sha256(checkpointData),
            canonicalByteCount: checkpointData.count,
            generation: checkpoint.history.generation,
            historyFrameCount: checkpoint.history.frames.count,
            latestFrameOrdinal: latest.ordinal
        ))
    }

    var temporal: ParityTemporalEvidence?
    if definition.kind == "pixel_temporal" {
        let continuous = try visibleFrameData(
            outputs[1],
            storage: storage,
            schedule: "row_major"
        )
        let resetFrame = try await processSinglePixelFrame(
            definition,
            pattern: definition.framePatterns[1],
            storage: storage,
            backend: backend,
            runtime: runtime
        )
        let sceneFrame = try visibleFrameData(
            outputs[2],
            storage: storage,
            schedule: "row_major"
        )
        let sceneResetFrame = try await processSinglePixelFrame(
            definition,
            pattern: definition.framePatterns[2],
            storage: storage,
            backend: backend,
            runtime: runtime
        )
        temporal = ParityTemporalEvidence(
            generations: checkpoints.map(\.generation),
            historyFrameCounts: checkpoints.map(\.historyFrameCount),
            continuousFrameDiffersFromReset: continuous != resetFrame,
            sceneCutEqualsSpatialReset: sceneFrame == sceneResetFrame,
            checkpointsCanonical: true
        )
    }
    let visible = try visibleSequenceData(
        outputs,
        storage: storage,
        schedule: "row_major"
    )
    let attachments = try canonicalJSON(ParityAttachmentEnvelope(
        schemaVersion: "mirmir-ash-v4-canonical-attachments-v1",
        frames: try outputs.enumerated().map {
            try frameAttachments($0.element, ordinal: $0.offset)
        },
        temporalCheckpoints: checkpoints
    ))
    var scheduled: [String: Data] = [:]
    for schedule in tileSchedules {
        scheduled[schedule] = try visibleSequenceData(
            outputs,
            storage: storage,
            schedule: schedule
        )
    }
    return ParityExecutionResult(
        visible: visible,
        attachments: attachments,
        visibleBySchedule: scheduled,
        sourcePaddingByteCount: sourcePadding,
        destinationPaddingByteCount: destinationPadding,
        paddingSentinelPreserved: paddingSentinelsPreserved,
        temporal: temporal
    )
}

private func processSinglePixelFrame(
    _ definition: ParityCaseDefinition,
    pattern: String,
    storage: PixelStorageV4,
    backend: FixedPointExecutionBackendV4,
    runtime: ASHVerifiedRuntimeBundleV4
) async throws -> Data {
    let configuration = DeterministicPreparedConfigurationV4(
        backendID: backend == .cpu
            ? .mirmirDeterministicCPU : .mirmirDeterministicMetal,
        executionBackend: backend,
        storage: storage,
        sourceWidth: definition.sourceWidth,
        sourceHeight: definition.sourceHeight,
        targetWidth: definition.targetWidth,
        targetHeight: definition.targetHeight,
        scanMode: .progressive
    )
    let device = backend == .metal ? MTLCreateSystemDefaultDevice() : nil
    let library = try device.map {
        try ASHP06MetalLibraryFactoryV4.makeLibrary(runtime: runtime, device: $0)
    }
    let prepared = try PreparedDeterministicV4Upscaler(
        configuration: configuration,
        runtime: runtime,
        metalDevice: device,
        metalLibrary: library
    )
    let source = try makePixelBuffer(
        storage: storage,
        width: definition.sourceWidth,
        height: definition.sourceHeight,
        metalCompatible: backend == .metal
    )
    try PixelBufferSignalCodecV4.write(
        makeSignalFrame(
            storage: storage,
            width: definition.sourceWidth,
            height: definition.sourceHeight,
            pattern: pattern
        ),
        to: source
    )
    installColorAttachments(on: source, storage: storage)
    let destination = try makePixelBuffer(
        storage: storage,
        width: definition.targetWidth,
        height: definition.targetHeight,
        metalCompatible: backend == .metal
    )
    try await prepared.process(
        source: FramePixelBuffer(source),
        destination: FramePixelBuffer(destination),
        timing: FrameTiming(
            frameIndex: 0,
            presentationTime: .zero,
            duration: CMTime(value: 1, timescale: 30)
        )
    )
    return try visibleFrameData(
        destination,
        storage: storage,
        schedule: "row_major"
    )
}

private func executeAlphaCase(
    _ definition: ParityCaseDefinition,
    backend: FixedPointExecutionBackendV4,
    runtime: ASHVerifiedRuntimeBundleV4,
    tileSchedules: [String]
) async throws -> ParityExecutionResult {
    let layout = try alphaLayout(definition.storage)
    let association = try alphaAssociation(definition.association)
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
    let samples = alphaSamples(
        width: definition.sourceWidth,
        height: definition.sourceHeight,
        maximum: layout.signalBitDepth == 8 ? 255 : 65_535,
        association: association
    )
    try Alpha4444PixelBufferAccessV4.write(samples, to: source, layout: layout)
    installAlphaAssociation(association, on: source)
    let sourcePaddingBeforeProcess = try packedPaddingBytes(
        source,
        layout: layout
    )
    let device = backend == .metal ? MTLCreateSystemDefaultDevice() : nil
    let library = try device.map {
        try ASHP06MetalLibraryFactoryV4.makeLibrary(runtime: runtime, device: $0)
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
        metalDevice: device,
        metalLibrary: library
    )
    try await scaler.process(source: source, destination: destination)
    let visible = try visiblePackedSequenceData(
        [destination],
        layout: layout,
        schedule: "row_major"
    )
    let attachments = try canonicalJSON(ParityAttachmentEnvelope(
        schemaVersion: "mirmir-ash-v4-canonical-attachments-v1",
        frames: [try frameAttachments(destination, ordinal: 0)],
        temporalCheckpoints: []
    ))
    var scheduled: [String: Data] = [:]
    for schedule in tileSchedules {
        scheduled[schedule] = try visiblePackedSequenceData(
            [destination],
            layout: layout,
            schedule: schedule
        )
    }
    let sourcePaddingBytes = try packedPaddingBytes(source, layout: layout)
    let destinationPaddingBytes = try packedPaddingBytes(
        destination,
        layout: layout
    )
    return ParityExecutionResult(
        visible: visible,
        attachments: attachments,
        visibleBySchedule: scheduled,
        sourcePaddingByteCount: sourcePaddingBytes.count,
        destinationPaddingByteCount: destinationPaddingBytes.count,
        paddingSentinelPreserved: sourcePaddingBytes == sourcePaddingBeforeProcess
            && destinationPaddingBytes.allSatisfy { $0 == 0xD3 },
        temporal: nil
    )
}

private func writeBackendArtifacts(
    name: String,
    first: ParityExecutionResult,
    repeatResult: ParityExecutionResult,
    schedules: [String],
    outputRoot: URL,
    directory: URL
) throws -> ParityBackendArtifacts {
    func write(_ data: Data, _ filename: String) throws -> ParityArtifact {
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return try artifact(url, relativeTo: outputRoot)
    }
    let visible = try write(first.visible, "\(name)-visible.bin")
    let attachments = try write(first.attachments, "\(name)-attachments.json")
    let repeatVisible = try write(
        repeatResult.visible,
        "\(name)-repeat-visible.bin"
    )
    let repeatAttachments = try write(
        repeatResult.attachments,
        "\(name)-repeat-attachments.json"
    )
    let scheduled = try schedules.map { schedule in
        guard let bytes = first.visibleBySchedule[schedule] else {
            throw ParityCaptureError.invalidOutput(
                "missing schedule \(schedule)"
            )
        }
        return ParityScheduleArtifact(
            schedule: schedule,
            artifact: try write(bytes, "\(name)-tile-\(schedule).bin")
        )
    }
    return ParityBackendArtifacts(
        visible: visible,
        attachments: attachments,
        repeatVisible: repeatVisible,
        repeatAttachments: repeatAttachments,
        tileSchedules: scheduled
    )
}

private func loadRuntime(mode: String) throws -> ASHVerifiedRuntimeBundleV4 {
    switch mode {
    case "production":
        guard ASHProductionP06TrustRootV4.isConfigured else {
            throw ParityCaptureError.invalidFixture(
                "the production P06 code trust root is not configured"
            )
        }
        return try ASHP06RuntimeProviderV4.production(bundle: .main).load()
    case "fixture":
        return try ASHV4SemanticArtifactTestSupport.executableSystemMetalRuntime()
    default:
        throw ParityCaptureError.invalidEnvironment("unknown runtime mode \(mode)")
    }
}

private func makeRuntimeRecord(
    _ runtime: ASHVerifiedRuntimeBundleV4,
    mode: String,
    expected: ParityReleaseRuntimeContract
) throws -> ParityRuntimeRecord {
    let manifestBytes: Data
    if mode == "production" {
        manifestBytes = try Data(contentsOf: runtime.bundleURL.appendingPathComponent(
            ASHRuntimeManifestV4.fileName
        ))
    } else {
        // The test support intentionally removes its temporary fixture bundle
        // immediately after loading. Fixture evidence is never release-eligible.
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
                "production runtime is not bound to the checked code trust root"
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
    default:
        throw ParityCaptureError.invalidContract("unsupported storage \(value)")
    }
}

private func alphaLayout(_ value: String) throws -> Alpha4444PackedLayoutV4 {
    switch value {
    case "bgra8": .bgra8
    case "argb16_big_endian": .argb16BigEndian
    default:
        throw ParityCaptureError.invalidContract("unsupported alpha layout \(value)")
    }
}

private func alphaAssociation(_ value: String) throws -> AlphaAssociationV4 {
    switch value {
    case "straight": .straight
    case "premultiplied": .premultiplied
    default:
        throw ParityCaptureError.invalidContract("unsupported alpha association")
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
    pattern: String
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
                    let bounds = plane.signalCodeBounds[component]
                    samples.append(patternValue(
                        pattern: pattern,
                        x: x,
                        y: y,
                        width: planeWidth,
                        height: planeHeight,
                        plane: planeIndex,
                        component: component,
                        bounds: bounds
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
    pattern: String,
    x: Int,
    y: Int,
    width: Int,
    height: Int,
    plane: Int,
    component: Int,
    bounds: PixelCodeBoundsV4
) -> UInt16 {
    let low = Int(bounds.minimum)
    let high = Int(bounds.maximum)
    let span = max(1, high - low)
    let value: Int
    switch pattern {
    case "moving_edge_0", "moving_edge_1":
        let shift = pattern == "moving_edge_0" ? 0 : 1
        let edge = max(1, width / 2 + shift)
        let base = x < edge ? low + span / 6 : high - span / 7
        value = base + ((y * 7 + component * 11 + plane * 13) % max(1, span / 10))
    case "scene_cut_white":
        value = high - ((x + y + component) % max(1, span / 32))
    case "rational_detail":
        value = low + ((x * 97 + y * 53 + component * 29 + plane * 71) % (span + 1))
    default:
        value = low + span / 2
    }
    return UInt16(min(high, max(low, value)))
}

private func installColorAttachments(
    on buffer: CVPixelBuffer,
    storage: PixelStorageV4
) {
    let hdr = storage == .p010VideoRange10Bit
        || storage == .p010FullRange10Bit
    CVBufferSetAttachment(
        buffer,
        kCVImageBufferColorPrimariesKey,
        hdr ? kCVImageBufferColorPrimaries_ITU_R_2020
            : kCVImageBufferColorPrimaries_ITU_R_709_2,
        .shouldPropagate
    )
    CVBufferSetAttachment(
        buffer,
        kCVImageBufferTransferFunctionKey,
        hdr ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            : kCVImageBufferTransferFunction_ITU_R_709_2,
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
        { reference, _ in reference?.deallocate() },
        storage,
        nil,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        storage.deallocate()
        throw ParityCaptureError.invalidFixture(
            "cannot create packed buffer: \(status)"
        )
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

private func visibleSequenceData(
    _ buffers: [CVPixelBuffer],
    storage: PixelStorageV4,
    schedule: String
) throws -> Data {
    var result = Data()
    appendUInt32(UInt32(buffers.count), to: &result)
    for buffer in buffers {
        result.append(try visibleFrameData(buffer, storage: storage, schedule: schedule))
    }
    return result
}

private func visibleFrameData(
    _ buffer: CVPixelBuffer,
    storage: PixelStorageV4,
    schedule: String
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
        let bytes = try tiledPlaneBytes(
            base: CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex),
            rowStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex),
            width: width,
            height: height,
            elementBytes: elementBytes,
            schedule: schedule
        )
        appendUInt32(UInt32(width), to: &result)
        appendUInt32(UInt32(height), to: &result)
        appendUInt32(UInt32(elementBytes), to: &result)
        appendUInt32(UInt32(bytes.count), to: &result)
        result.append(bytes)
    }
    return result
}

private func visiblePackedSequenceData(
    _ buffers: [CVPixelBuffer],
    layout: Alpha4444PackedLayoutV4,
    schedule: String
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
        let bytes = try tiledPlaneBytes(
            base: CVPixelBufferGetBaseAddress(buffer),
            rowStride: CVPixelBufferGetBytesPerRow(buffer),
            width: width,
            height: height,
            elementBytes: layout.bytesPerPixel,
            schedule: schedule
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

private struct ParityTile {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

private func tiledPlaneBytes(
    base: UnsafeMutableRawPointer?,
    rowStride: Int,
    width: Int,
    height: Int,
    elementBytes: Int,
    schedule: String
) throws -> Data {
    guard let base, rowStride >= width * elementBytes else {
        throw ParityCaptureError.invalidFixture("invalid visible plane")
    }
    var tiles: [ParityTile] = []
    let tileWidth = 3
    let tileHeight = 2
    for y in stride(from: 0, to: height, by: tileHeight) {
        for x in stride(from: 0, to: width, by: tileWidth) {
            tiles.append(ParityTile(
                x: x,
                y: y,
                width: min(tileWidth, width - x),
                height: min(tileHeight, height - y)
            ))
        }
    }
    switch schedule {
    case "row_major": break
    case "reverse": tiles.reverse()
    case "even_then_odd":
        tiles = tiles.enumerated().filter { $0.offset.isMultiple(of: 2) }
            .map(\.element)
            + tiles.enumerated().filter { !$0.offset.isMultiple(of: 2) }
                .map(\.element)
    default:
        throw ParityCaptureError.invalidContract("unknown tile schedule")
    }
    let source = base.assumingMemoryBound(to: UInt8.self)
    var destination = [UInt8](
        repeating: 0xEE,
        count: width * height * elementBytes
    )
    var copied = [Bool](repeating: false, count: width * height)
    for tile in tiles {
        for localY in 0..<tile.height {
            for localX in 0..<tile.width {
                let x = tile.x + localX
                let y = tile.y + localY
                let pixel = y * width + x
                guard !copied[pixel] else {
                    throw ParityCaptureError.invalidFixture("tile overlap")
                }
                copied[pixel] = true
                for byte in 0..<elementBytes {
                    destination[pixel * elementBytes + byte]
                        = source[y * rowStride + x * elementBytes + byte]
                }
            }
        }
    }
    guard copied.allSatisfy({ $0 }) else {
        throw ParityCaptureError.invalidFixture("tile gap")
    }
    return Data(destination)
}

private func frameAttachments(
    _ buffer: CVPixelBuffer,
    ordinal: Int
) throws -> ParityFrameAttachments {
    let keys: [CFString] = [
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferChromaLocationBottomFieldKey,
        kCVImageBufferFieldCountKey,
        kCVImageBufferFieldDetailKey,
        kCVImageBufferAlphaChannelModeKey,
        kCVImageBufferAlphaChannelIsOpaque,
        kCVImageBufferMasteringDisplayColorVolumeKey,
        kCVImageBufferContentLightLevelInfoKey,
        kCVImageBufferAmbientViewingEnvironmentKey,
        kCMSampleAttachmentKey_HDR10PlusPerFrameData,
        kCMSampleAttachmentKey_PostDecodeProcessingMetadata
    ]
    var values: [ParityAttachmentValue] = []
    for key in keys {
        var mode = CVAttachmentMode.shouldNotPropagate
        guard let value = CVBufferCopyAttachment(buffer, key, &mode) else {
            continue
        }
        values.append(ParityAttachmentValue(
            key: key as String,
            mode: mode == .shouldPropagate
                ? "should_propagate" : "should_not_propagate",
            value: try canonicalAttachmentValue(value)
        ))
    }
    return ParityFrameAttachments(
        ordinal: ordinal,
        values: values.sorted { $0.key < $1.key }
    )
}

private func canonicalAttachmentValue(_ value: CFTypeRef) throws -> String {
    if CFGetTypeID(value) == CFStringGetTypeID() {
        return "string:" + (value as! String)
    }
    if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return "boolean:" + (CFBooleanGetValue((value as! CFBoolean))
            ? "true" : "false")
    }
    if CFGetTypeID(value) == CFNumberGetTypeID() {
        return "number:" + (value as! NSNumber).stringValue
    }
    if CFGetTypeID(value) == CFDataGetTypeID() {
        return "data:" + (value as! Data).base64EncodedString()
    }
    guard PropertyListSerialization.propertyList(
        value,
        isValidFor: .binary
    ) else {
        throw ParityCaptureError.invalidFixture("unsupported attachment value")
    }
    let data = try PropertyListSerialization.data(
        fromPropertyList: value,
        format: .binary,
        options: 0
    )
    return "plist:" + data.base64EncodedString()
}

private func fillAllStorageBytes(
    _ buffer: CVPixelBuffer,
    sentinel: UInt8
) throws {
    let status = CVPixelBufferLockBaseAddress(buffer, [])
    guard status == kCVReturnSuccess else {
        throw ParityCaptureError.invalidFixture("cannot initialize buffer")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
            throw ParityCaptureError.invalidFixture("missing plane")
        }
        let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            * CVPixelBufferGetHeightOfPlane(buffer, plane)
        base.initializeMemory(as: UInt8.self, repeating: sentinel, count: count)
    }
}

private func paddingByteCount(
    _ buffer: CVPixelBuffer,
    storage: PixelStorageV4
) throws -> Int {
    let layout = PixelLayoutV4(storage: storage)
    return try layout.planes.enumerated().reduce(0) { result, item in
        let (planeIndex, plane) = item
        let active = try plane.activeBytesPerRow(
            frameWidth: CVPixelBufferGetWidth(buffer)
        )
        return result + (
            CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex) - active
        ) * CVPixelBufferGetHeightOfPlane(buffer, planeIndex)
    }
}

private func paddingBytes(
    _ buffer: CVPixelBuffer,
    storage: PixelStorageV4
) throws -> [UInt8] {
    let layout = PixelLayoutV4(storage: storage)
    let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
    guard status == kCVReturnSuccess else {
        throw ParityCaptureError.invalidFixture("cannot inspect padding")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    var result: [UInt8] = []
    for (planeIndex, plane) in layout.planes.enumerated() {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex) else {
            throw ParityCaptureError.invalidFixture("missing padding plane")
        }
        let active = try plane.activeBytesPerRow(
            frameWidth: CVPixelBufferGetWidth(buffer)
        )
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(buffer, planeIndex)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height where rowBytes > active {
            result.append(contentsOf: UnsafeBufferPointer(
                start: bytes.advanced(by: y * rowBytes + active),
                count: rowBytes - active
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
        throw ParityCaptureError.invalidFixture("cannot inspect packed padding")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let active = CVPixelBufferGetWidth(buffer) * layout.bytesPerPixel
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    var result: [UInt8] = []
    for y in 0..<CVPixelBufferGetHeight(buffer) where rowBytes > active {
        result.append(contentsOf: UnsafeBufferPointer(
            start: bytes.advanced(by: y * rowBytes + active),
            count: rowBytes - active
        ))
    }
    return result
}

private func makeArtifactManifest(
    root: URL,
    excluding: Set<String>
) throws -> ParityArtifactManifest {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw ParityCaptureError.invalidOutput("cannot enumerate output")
    }
    var artifacts: [ParityArtifact] = []
    for case let url as URL in enumerator {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isSymbolicLink != true else {
            throw ParityCaptureError.invalidOutput("symbolic link in output")
        }
        guard values.isRegularFile == true else { continue }
        let relative = relativePath(url, to: root)
        if excluding.contains(relative) { continue }
        artifacts.append(try artifact(url, relativeTo: root))
    }
    return ParityArtifactManifest(
        schemaVersion: "mirmir-ash-v4-cpu-metal-parity-artifacts-v1",
        artifacts: artifacts.sorted { $0.path < $1.path }
    )
}

private func artifact(_ url: URL, relativeTo root: URL) throws -> ParityArtifact {
    let data = try Data(contentsOf: url)
    return ParityArtifact(
        path: relativePath(url, to: root),
        byteCount: data.count,
        sha256: sha256(data)
    )
}

private func relativePath(_ url: URL, to root: URL) -> String {
    let prefix = root.standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    precondition(path.hasPrefix(prefix))
    return String(path.dropFirst(prefix.count))
}

private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data([0x0A])
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy {
        $0.isNumber || ("a"..."f").contains(String($0))
    }
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
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue,
              try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty
        else {
            throw ParityCaptureError.invalidOutput(
                "capture directory must be new or empty"
            )
        }
    } else {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}
