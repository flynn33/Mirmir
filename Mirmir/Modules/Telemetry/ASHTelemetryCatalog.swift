import Foundation

enum ASHTelemetryStage: String, CaseIterable, Codable, Sendable {
    case mediaProbe = "media_probe"
    case readerSetup = "reader_setup"
    case frameRead = "frame_read"
    case canonicalize
    case analyzeLuma = "analyze_luma"
    case analyzeChroma = "analyze_chroma"
    case motionEstimate = "motion_estimate"
    case statePack = "state_pack"
    case dispatchDecode = "dispatch_decode"
    case reconstructLuma = "reconstruct_luma"
    case reconstructChroma = "reconstruct_chroma"
    case temporalFuse = "temporal_fuse"
    case telemetryReduce = "telemetry_reduce"
    case writerBackpressure = "writer_backpressure"
    case writerAppend = "writer_append"
    case audioProcess = "audio_process"
    case writerFinish = "writer_finish"
    case reopenVerify = "reopen_verify"
    case frameTotal = "frame_total"
    case jobTotal = "job_total"

    var signpostName: StaticString {
        switch self {
        case .mediaProbe: "media_probe"
        case .readerSetup: "reader_setup"
        case .frameRead: "frame_read"
        case .canonicalize: "canonicalize"
        case .analyzeLuma: "analyze_luma"
        case .analyzeChroma: "analyze_chroma"
        case .motionEstimate: "motion_estimate"
        case .statePack: "state_pack"
        case .dispatchDecode: "dispatch_decode"
        case .reconstructLuma: "reconstruct_luma"
        case .reconstructChroma: "reconstruct_chroma"
        case .temporalFuse: "temporal_fuse"
        case .telemetryReduce: "telemetry_reduce"
        case .writerBackpressure: "writer_backpressure"
        case .writerAppend: "writer_append"
        case .audioProcess: "audio_process"
        case .writerFinish: "writer_finish"
        case .reopenVerify: "reopen_verify"
        case .frameTotal: "frame_total"
        case .jobTotal: "job_total"
        }
    }
}

enum ASHTelemetryCounter: String, CaseIterable, Codable, Sendable {
    case stateHistogram512 = "state_histogram_512"
    case messageHistogram16 = "message_histogram_16"
    case operatorHistogram16 = "operator_histogram_16"
    case decodeExact = "decode_exact"
    case decodeCorrected = "decode_corrected"
    case decodeRejected = "decode_rejected"
    case candidateOne = "candidate_one"
    case candidateTwo = "candidate_two"
    case candidateMoreThanTwo = "candidate_more_than_two"
    case runtimeTreeGenerations = "runtime_tree_generations"
    case fullFrameCPULoops = "full_frame_cpu_loops"
    case fullFrameGPUReadbacks = "full_frame_gpu_readbacks"
    case fullFrameCopies = "full_frame_copies"
    case commandBufferErrors = "command_buffer_errors"
    case inFlightFrames = "in_flight_frames"
    case partialCleanupFailures = "partial_cleanup_failures"
}

enum ASHTelemetryRunStatus: String, Codable, Sendable {
    case running
    case success
    case failure
    case cancelled
}

enum ASHTelemetryEventKind: String, Codable, Sendable {
    case runStarted = "run_started"
    case stageBegan = "stage_began"
    case stageEnded = "stage_ended"
    case commandBuffer = "command_buffer"
    case media
    case error
    case terminal
}

enum ASHTelemetryUpdateResult: String, Codable, Sendable {
    case applied
    case saturated
    case rejectedOutOfBounds = "rejected_out_of_bounds"
    case ignoredAfterTerminal = "ignored_after_terminal"
}

struct ASHTelemetryStageToken: Hashable, Sendable {
    let id: UUID
    let stage: ASHTelemetryStage
}
