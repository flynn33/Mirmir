import Foundation

enum R09ResidualAuthorizationScope: String, Hashable, Sendable {
    case deterministicSimulationOnly = "deterministic_simulation_only"
}

struct R09ResidualAuthorizationIdentity: Hashable, Sendable {
    let authorizationID: String
    let referencedR08AcceptanceSHA256: String
    let scope: R09ResidualAuthorizationScope
    let frameID: String
    let shotID: String
    let streamID: String
    let stateGeneration: Int64
    let sourceReferenceFrameID: String
    let sourceReferenceFrameOrdinal: Int64
    let temporalReferenceFrameID: String
    let temporalReferenceFrameOrdinal: Int64
    let primaryBackendID: String
    let primaryProcessingIdentity: AppleUpscaleProcessingIdentity

    init(
        authorizationID: String,
        referencedR08AcceptanceSHA256: String,
        scope: R09ResidualAuthorizationScope,
        frameID: String,
        shotID: String,
        streamID: String,
        stateGeneration: Int64,
        sourceReferenceFrameID: String,
        sourceReferenceFrameOrdinal: Int64,
        temporalReferenceFrameID: String,
        temporalReferenceFrameOrdinal: Int64,
        primaryBackendID: String,
        primaryProcessingIdentity: AppleUpscaleProcessingIdentity
    ) throws {
        guard stateGeneration >= 0 else {
            throw R09ResidualContractError.invalidStateGeneration(stateGeneration)
        }
        guard sourceReferenceFrameOrdinal >= 0 else {
            throw R09ResidualContractError.invalidFrameOrdinal(
                role: "authorization_source_reference",
                value: sourceReferenceFrameOrdinal
            )
        }
        guard temporalReferenceFrameOrdinal >= 0 else {
            throw R09ResidualContractError.invalidFrameOrdinal(
                role: "authorization_temporal_reference",
                value: temporalReferenceFrameOrdinal
            )
        }
        guard primaryProcessingIdentity.route.backend.backendID == primaryBackendID else {
            throw R09ResidualContractError.invalidExecutionBinding
        }
        self.authorizationID = try R09ResidualValidation.identity(
            authorizationID,
            field: "authorization_id"
        )
        self.referencedR08AcceptanceSHA256 = try R09ResidualValidation.sha256(
            referencedR08AcceptanceSHA256,
            field: "referenced_r08_acceptance_sha256"
        )
        self.scope = scope
        self.frameID = try R09ResidualValidation.identity(
            frameID,
            field: "authorization_frame_id"
        )
        self.shotID = try R09ResidualValidation.identity(
            shotID,
            field: "authorization_shot_id"
        )
        self.streamID = try R09ResidualValidation.identity(
            streamID,
            field: "authorization_stream_id"
        )
        self.stateGeneration = stateGeneration
        self.sourceReferenceFrameID = try R09ResidualValidation.identity(
            sourceReferenceFrameID,
            field: "authorization_source_reference_frame_id"
        )
        self.sourceReferenceFrameOrdinal = sourceReferenceFrameOrdinal
        self.temporalReferenceFrameID = try R09ResidualValidation.identity(
            temporalReferenceFrameID,
            field: "authorization_temporal_reference_frame_id"
        )
        self.temporalReferenceFrameOrdinal = temporalReferenceFrameOrdinal
        self.primaryBackendID = try R09ResidualValidation.identity(
            primaryBackendID,
            field: "authorization_primary_backend_id"
        )
        self.primaryProcessingIdentity = primaryProcessingIdentity
    }
}
enum R09AppleScalerKind: String, Hashable, Sendable {
    case metalPerformanceShaders = "metal_performance_shaders"
    case coreImage = "core_image"
    case vImage = "vimage"
    case videoToolbox = "video_toolbox"
    case metalFXSpatial = "metalfx_spatial"
    case customMetal = "custom_metal"
}

enum R09ResidualExecutionMode: String, Hashable, Sendable {
    case deterministicFixtureSimulation = "deterministic_fixture_simulation"
    case nativeCoreAI = "native_core_ai"
}

enum R09NativeExecutionDisposition: String, Hashable, Sendable {
    case notObserved = "not_observed"
    case observed
}

struct R09AppleScalerIdentity: Hashable, Sendable {
    static let deterministicPrimaryBackendID = "r03.mps.lanczos"
    static let deterministicPrimaryBackendVersion = "r03.functional.v2"

    let backendID: String
    let implementationVersion: String
    let processingIdentity: AppleUpscaleProcessingIdentity
    let outputFrameID: String
    let kind: R09AppleScalerKind
    let scaleNumerator: Int
    let scaleDenominator: Int
    let executionMode: R09ResidualExecutionMode
    let nativeExecution: R09NativeExecutionDisposition

    init(
        backendID: String,
        implementationVersion: String,
        processingIdentity: AppleUpscaleProcessingIdentity,
        outputFrameID: String,
        kind: R09AppleScalerKind,
        scaleNumerator: Int,
        scaleDenominator: Int,
        executionMode: R09ResidualExecutionMode,
        nativeExecution: R09NativeExecutionDisposition
    ) throws {
        guard scaleNumerator > 0, scaleDenominator > 0 else {
            throw R09ResidualContractError.invalidScale(
                numerator: scaleNumerator,
                denominator: scaleDenominator
            )
        }
        try R09ResidualValidation.executionBinding(
            mode: executionMode,
            nativeExecution: nativeExecution
        )
        guard processingIdentity.route.backend.backendID == backendID,
              processingIdentity.route.backend.backendRevision
                == implementationVersion else {
            throw R09ResidualContractError.invalidExecutionBinding
        }
        self.backendID = try R09ResidualValidation.identity(backendID, field: "scaler_backend_id")
        self.implementationVersion = try R09ResidualValidation.identity(
            implementationVersion,
            field: "scaler_implementation_version"
        )
        self.processingIdentity = processingIdentity
        self.outputFrameID = try R09ResidualValidation.identity(
            outputFrameID,
            field: "scaler_output_frame_id"
        )
        self.kind = kind
        self.scaleNumerator = scaleNumerator
        self.scaleDenominator = scaleDenominator
        self.executionMode = executionMode
        self.nativeExecution = nativeExecution
    }
}

enum R09ResidualArtifactKind: String, Hashable, Sendable {
    case deterministicSimulationContract = "deterministic_simulation_contract"
    case coreAIModel = "core_ai_model"
}

struct R09ResidualModelIdentity: Hashable, Sendable {
    static let deterministicModelID = "r09.deterministic-local-residual"
    static let deterministicModelVersion = "1"
    static let deterministicProviderSHA256 =
        "81bf3a87d5c4fd925a369f7c715e67fd5878e4d0aef31415aea887d61ad152dd"
    static let deterministicPreprocessingIdentity =
        "r09.preprocessing.nv12-planar-q16.v1"
    static let deterministicPostprocessingIdentity =
        "r09.postprocessing.signed-residual-q16.v1"
    static let deterministicResidualContractIdentity =
        "r09.residual-contract.planar-signed-q16.v1"

    let modelID: String
    let modelVersion: String
    let artifactKind: R09ResidualArtifactKind
    let contentSHA256: String
    let preprocessingIdentity: String
    let postprocessingIdentity: String
    let residualContractIdentity: String

    init(
        modelID: String,
        modelVersion: String,
        artifactKind: R09ResidualArtifactKind,
        contentSHA256: String,
        preprocessingIdentity: String,
        postprocessingIdentity: String,
        residualContractIdentity: String
    ) throws {
        self.modelID = try R09ResidualValidation.identity(modelID, field: "model_id")
        self.modelVersion = try R09ResidualValidation.identity(modelVersion, field: "model_version")
        self.artifactKind = artifactKind
        self.contentSHA256 = try R09ResidualValidation.sha256(
            contentSHA256,
            field: "model_content_sha256"
        )
        self.preprocessingIdentity = try R09ResidualValidation.identity(
            preprocessingIdentity,
            field: "preprocessing_identity"
        )
        self.postprocessingIdentity = try R09ResidualValidation.identity(
            postprocessingIdentity,
            field: "postprocessing_identity"
        )
        self.residualContractIdentity = try R09ResidualValidation.identity(
            residualContractIdentity,
            field: "residual_contract_identity"
        )
    }
}

struct R09ResidualRequestIdentity: Hashable, Sendable {
    static let ioContractSHA256 =
        "495455204df9134c2a3910807c33fbcf84ae21fdd1dc96817aecf6b5a2b6ff24"

    let frameID: String
    let shotID: String
    let streamID: String
    let frameOrdinal: Int64
    let stateGeneration: Int64
    let ioContractSHA256: String

    init(
        frameID: String,
        shotID: String,
        streamID: String,
        frameOrdinal: Int64,
        stateGeneration: Int64,
        ioContractSHA256: String
    ) throws {
        guard frameOrdinal >= 0 else {
            throw R09ResidualContractError.invalidFrameOrdinal(
                role: "request",
                value: frameOrdinal
            )
        }
        guard stateGeneration >= 0 else {
            throw R09ResidualContractError.invalidStateGeneration(stateGeneration)
        }
        self.frameID = try R09ResidualValidation.identity(frameID, field: "frame_id")
        self.shotID = try R09ResidualValidation.identity(shotID, field: "shot_id")
        self.streamID = try R09ResidualValidation.identity(streamID, field: "stream_id")
        self.frameOrdinal = frameOrdinal
        self.stateGeneration = stateGeneration
        self.ioContractSHA256 = try R09ResidualValidation.sha256(
            ioContractSHA256,
            field: "io_contract_sha256"
        )
    }
}

struct R09ResidualExecutionIdentity: Hashable, Sendable {
    static let deterministicSimulationV1 = makeDeterministicSimulationV1()

    let runtimeID: String
    let modelContentSHA256: String
    let ioContractSHA256: String
    let mode: R09ResidualExecutionMode
    let nativeExecution: R09NativeExecutionDisposition

    init(
        runtimeID: String,
        modelContentSHA256: String,
        ioContractSHA256: String,
        mode: R09ResidualExecutionMode,
        nativeExecution: R09NativeExecutionDisposition
    ) throws {
        try R09ResidualValidation.executionBinding(
            mode: mode,
            nativeExecution: nativeExecution
        )
        self.runtimeID = try R09ResidualValidation.identity(runtimeID, field: "runtime_id")
        self.modelContentSHA256 = try R09ResidualValidation.sha256(
            modelContentSHA256,
            field: "execution_model_content_sha256"
        )
        self.ioContractSHA256 = try R09ResidualValidation.sha256(
            ioContractSHA256,
            field: "execution_io_contract_sha256"
        )
        self.mode = mode
        self.nativeExecution = nativeExecution
    }

    private static func makeDeterministicSimulationV1() -> Self {
        do {
            return try Self(
                runtimeID: "r09.deterministic-residual-simulation.v1",
                modelContentSHA256: R09ResidualModelIdentity.deterministicProviderSHA256,
                ioContractSHA256: R09ResidualRequestIdentity.ioContractSHA256,
                mode: .deterministicFixtureSimulation,
                nativeExecution: .notObserved
            )
        } catch {
            preconditionFailure("Invalid internal R09 execution identity: \(error)")
        }
    }
}
