import CoreMedia
import Foundation

enum FixtureError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case invalidFixture(String)
    case operation(String, OSStatus)
    case failed(String)

    var description: String {
        switch self {
        case .invalidArgument(let message), .invalidFixture(let message), .failed(let message):
            return message
        case .operation(let operation, let status):
            return "\(operation) failed with OSStatus \(status)"
        }
    }
}

struct LockedTime: Codable, Equatable {
    let value: Int64
    let timescale: Int32

    var cmTime: CMTime {
        CMTime(value: value, timescale: timescale)
    }
}

struct ExactTime: Codable, Equatable {
    let value: Int64
    let timescale: Int32
    let flags: UInt32
    let epoch: Int64

    init(_ time: CMTime) {
        value = time.value
        timescale = time.timescale
        flags = time.flags.rawValue
        epoch = time.epoch
    }
}

extension ExactTime {
    var cmTime: CMTime {
        CMTime(
            value: value,
            timescale: timescale,
            flags: CMTimeFlags(rawValue: flags),
            epoch: epoch
        )
    }
}

struct PlaneHashes: Codable, Equatable {
    let luma: String
    let chromaBlue: String
    let chromaRed: String

    enum CodingKeys: String, CodingKey {
        case luma = "Y"
        case chromaBlue = "Cb"
        case chromaRed = "Cr"
    }
}

struct SourceFrameLock: Codable {
    let index: Int
    let presentationTime: LockedTime
    let duration: LockedTime
    let activeRowSha256: PlaneHashes
    let frameNv12Sha256: String

    enum CodingKeys: String, CodingKey {
        case index
        case presentationTime = "presentation_time"
        case duration
        case activeRowSha256 = "active_row_sha256"
        case frameNv12Sha256 = "frame_nv12_sha256"
    }
}

struct CodecSourceOrigin: Codable {
    let degradationProfileId: String
    let degradationPolicySha256: String

    enum CodingKeys: String, CodingKey {
        case degradationProfileId = "degradation_profile_id"
        case degradationPolicySha256 = "degradation_policy_sha256"
    }
}

struct CodecSourcePixelLayout: Codable {
    let pixelFormat: String
    let range: String
    let colorPrimaries: String
    let transferFunction: String
    let yCbCrMatrix: String
    let chromaLocationTopField: String
    let chromaLocationBottomField: String
    let width: Int
    let height: Int

    enum CodingKeys: String, CodingKey {
        case pixelFormat = "pixel_format"
        case range
        case colorPrimaries = "color_primaries"
        case transferFunction = "transfer_function"
        case yCbCrMatrix = "ycbcr_matrix"
        case chromaLocationTopField = "chroma_location_top_field"
        case chromaLocationBottomField = "chroma_location_bottom_field"
        case width, height
    }
}

struct SourceFixtureLock: Codable {
    let fixtureId: String
    let source: CodecSourceOrigin
    let pixelLayout: CodecSourcePixelLayout
    let frameCount: Int
    let frames: [SourceFrameLock]
    let payloadSizeBytes: Int
    let payloadSha256: String

    enum CodingKeys: String, CodingKey {
        case fixtureId = "fixture_id"
        case source
        case pixelLayout = "pixel_layout"
        case frameCount = "frame_count"
        case frames
        case payloadSizeBytes = "payload_size_bytes"
        case payloadSha256 = "payload_sha256"
    }
}

struct AttachmentEvidence: Codable, Equatable {
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
    let chromaLocationTopField: String?
    let chromaLocationBottomField: String?
    let range: String

    enum CodingKeys: String, CodingKey {
        case colorPrimaries = "color_primaries"
        case transferFunction = "transfer_function"
        case yCbCrMatrix = "ycbcr_matrix"
        case chromaLocationTopField = "chroma_location_top_field"
        case chromaLocationBottomField = "chroma_location_bottom_field"
        case range
    }
}

struct DecodedFrameEvidence: Codable, Equatable {
    let index: Int
    let presentationTime: ExactTime
    let duration: ExactTime
    let width: Int
    let height: Int
    let pixelFormat: String
    let activeRowSha256: PlaneHashes
    let attachments: AttachmentEvidence

    enum CodingKeys: String, CodingKey {
        case index
        case presentationTime = "presentation_time"
        case duration, width, height
        case pixelFormat = "pixel_format"
        case activeRowSha256 = "active_row_sha256"
        case attachments
    }
}

struct DecodeRunEvidence: Codable, Equatable {
    let runIndex: Int
    let frames: [DecodedFrameEvidence]

    enum CodingKeys: String, CodingKey {
        case runIndex = "run_index"
        case frames
    }
}

struct DecoderIdentity: Codable, Equatable {
    let framework: String
    let sessionType: String
    let codec: String
    let hardwareAccelerationControl: String
    let hardwareAccelerated: Bool?
    let hardwareAccelerationPropertyAvailable: Bool?
    let publicDecoderIdentifier: String

    enum CodingKeys: String, CodingKey {
        case framework
        case sessionType = "session_type"
        case codec
        case hardwareAccelerationControl = "hardware_acceleration_control"
        case hardwareAccelerated = "hardware_accelerated"
        case hardwareAccelerationPropertyAvailable = "hardware_acceleration_property_available"
        case publicDecoderIdentifier = "public_decoder_identifier"
    }
}

struct DecoderRouteEvidence: Codable, Equatable {
    let route: String
    let identity: DecoderIdentity
    let runs: [DecodeRunEvidence]
}

struct SourceEvidence: Codable {
    let payloadPath: String
    let payloadSha256: String
    let payloadSizeBytes: Int
    let sourceLockPath: String
    let sourceLockSha256: String
    let degradationProfileId: String
    let degradationPolicySha256: String

    enum CodingKeys: String, CodingKey {
        case payloadPath = "payload_path"
        case payloadSha256 = "payload_sha256"
        case payloadSizeBytes = "payload_size_bytes"
        case sourceLockPath = "source_lock_path"
        case sourceLockSha256 = "source_lock_sha256"
        case degradationProfileId = "degradation_profile_id"
        case degradationPolicySha256 = "degradation_policy_sha256"
    }
}

struct EncodedFixtureEvidence: Codable {
    let path: String
    let sha256: String
    let sizeBytes: Int
    let container: String
    let codec: String
    let width: Int
    let height: Int
    let frameCount: Int
    let duration: ExactTime
    let formatAttachments: AttachmentEvidence

    enum CodingKeys: String, CodingKey {
        case path, sha256, container, codec, width, height, duration
        case sizeBytes = "size_bytes"
        case frameCount = "frame_count"
        case formatAttachments = "format_attachments"
    }
}

struct EncoderEvidence: Codable {
    let framework: String
    let sessionType: String
    let encoderId: String
    let encoderName: String
    let displayName: String
    let hardwareAccelerated: Bool
    let hardwareAccelerationPropertyAvailable: Bool
    let hardwareAccelerationVerification: String
    let realTime: Bool
    let allowFrameReordering: Bool
    let allowTemporalCompression: Bool
    let maxKeyFrameInterval: Int
    let allFramesSync: Bool
    let profileLevel: String
    let averageBitRate: Int
    let dataRateLimitBytes: Int
    let dataRateLimitSeconds: Int
    let expectedFrameRate: Int
    let pixelFormat: String
    let colorPrimaries: String
    let transferFunction: String
    let yCbCrMatrix: String
    let chromaLocation: String

    enum CodingKeys: String, CodingKey {
        case framework
        case sessionType = "session_type"
        case encoderId = "encoder_id"
        case encoderName = "encoder_name"
        case displayName = "display_name"
        case hardwareAccelerated = "hardware_accelerated"
        case hardwareAccelerationPropertyAvailable = "hardware_acceleration_property_available"
        case hardwareAccelerationVerification = "hardware_acceleration_verification"
        case realTime = "real_time"
        case allowFrameReordering = "allow_frame_reordering"
        case allowTemporalCompression = "allow_temporal_compression"
        case maxKeyFrameInterval = "max_key_frame_interval"
        case allFramesSync = "all_frames_sync"
        case profileLevel = "profile_level"
        case averageBitRate = "average_bit_rate"
        case dataRateLimitBytes = "data_rate_limit_bytes"
        case dataRateLimitSeconds = "data_rate_limit_seconds"
        case expectedFrameRate = "expected_frame_rate"
        case pixelFormat = "pixel_format"
        case colorPrimaries = "color_primaries"
        case transferFunction = "transfer_function"
        case yCbCrMatrix = "ycbcr_matrix"
        case chromaLocation = "chroma_location"
    }
}

struct VerificationEvidence: Codable {
    let softwareDecodeRunCount: Int
    let productReaderRunCount: Int
    let softwareRunsPixelIdentical: Bool
    let productReaderRunsPixelIdentical: Bool
    let crossRoutePixelIdentical: Bool
    let exactTimingPreserved: Bool
    let dimensionsPreserved: Bool
    let pixelFormatPreserved: Bool
    let attachmentsRecorded: Bool
    let rowPaddingExcluded: Bool

    enum CodingKeys: String, CodingKey {
        case softwareDecodeRunCount = "software_decode_run_count"
        case productReaderRunCount = "product_reader_run_count"
        case softwareRunsPixelIdentical = "software_runs_pixel_identical"
        case productReaderRunsPixelIdentical = "product_reader_runs_pixel_identical"
        case crossRoutePixelIdentical = "cross_route_pixel_identical"
        case exactTimingPreserved = "exact_timing_preserved"
        case dimensionsPreserved = "dimensions_preserved"
        case pixelFormatPreserved = "pixel_format_preserved"
        case attachmentsRecorded = "attachments_recorded"
        case rowPaddingExcluded = "row_padding_excluded"
    }
}

struct EnvironmentEvidence: Codable {
    let macos: String
    let xcode: String
    let swift: String
    let architecture: String
    let hardwareModel: String
    let processor: String

    enum CodingKeys: String, CodingKey {
        case macos, xcode, swift, architecture, processor
        case hardwareModel = "hardware_model"
    }
}

struct DegradationLockIntegration: Codable {
    let id: String
    let kind: String
    let version: String
    let sourceProfileId: String
    let fixturePath: String
    let fixtureSha256: String
    let evidencePath: String
    let decodedPixelsDeterministic: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, version
        case sourceProfileId = "source_profile_id"
        case fixturePath = "fixture_path"
        case fixtureSha256 = "fixture_sha256"
        case evidencePath = "evidence_path"
        case decodedPixelsDeterministic = "deterministic_decoded_pixels_on_recorded_environment"
    }
}

struct BenchmarkIntegration: Codable {
    let comparisonDomainsExecuted: [String]
    let actualCodecFixtureUsed: Bool
    let actualCodecFixtureId: String
    let containerDecodedFrameCount: Int
    let holdoutAccessed: Bool

    enum CodingKeys: String, CodingKey {
        case comparisonDomainsExecuted = "comparison_domains_executed"
        case actualCodecFixtureUsed = "actual_codec_fixture_used"
        case actualCodecFixtureId = "actual_codec_fixture_id"
        case containerDecodedFrameCount = "container_decoded_frame_count"
        case holdoutAccessed = "holdout_accessed"
    }
}

struct IntegrationEvidence: Codable {
    let degradationLockProfile: DegradationLockIntegration
    let benchmarkDryRunFields: BenchmarkIntegration

    enum CodingKeys: String, CodingKey {
        case degradationLockProfile = "degradation_lock_profile"
        case benchmarkDryRunFields = "benchmark_dry_run_fields"
    }
}

struct LimitationEvidence: Codable {
    let crossOsBitstreamStabilityClaimed: Bool
    let regenerationBitstreamStabilityClaimed: Bool
    let bitstreamScope: String
    let productReaderAccelerationVisibility: String

    enum CodingKeys: String, CodingKey {
        case crossOsBitstreamStabilityClaimed = "cross_os_bitstream_stability_claimed"
        case regenerationBitstreamStabilityClaimed = "regeneration_bitstream_stability_claimed"
        case bitstreamScope = "bitstream_scope"
        case productReaderAccelerationVisibility = "product_reader_acceleration_visibility"
    }
}

struct ActualCodecFixtureReport: Codable {
    let schemaVersion: String
    let artifactKind: String
    let fixtureId: String
    let status: String
    let source: SourceEvidence
    let fixture: EncodedFixtureEvidence
    let encoder: EncoderEvidence
    let decoderRoutes: [DecoderRouteEvidence]
    let verification: VerificationEvidence
    let environment: EnvironmentEvidence
    let integration: IntegrationEvidence
    let limitations: LimitationEvidence

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case artifactKind = "artifact_kind"
        case fixtureId = "fixture_id"
        case status, source, fixture, encoder
        case decoderRoutes = "decoder_routes"
        case verification, environment, integration, limitations
    }
}

struct FailureEvidence: Codable {
    let schemaVersion = "1.0.0"
    let artifactKind = "actual_codec_fixture_failure"
    let status = "fail"
    let errorType: String
    let message: String
    let requestedFixturePath: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case artifactKind = "artifact_kind"
        case status
        case errorType = "error_type"
        case message
        case requestedFixturePath = "requested_fixture_path"
    }
}
