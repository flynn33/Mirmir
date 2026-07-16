import Foundation

struct CommonWriterSourceFrame: Codable {
    let caseId: String
    let index: Int
    let presentationTime: LockedTime
    let duration: LockedTime
    let activeRowSha256: PlaneHashes
    let frameNv12Sha256: String

    enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
        case index
        case presentationTime = "presentation_time"
        case duration
        case activeRowSha256 = "active_row_sha256"
        case frameNv12Sha256 = "frame_nv12_sha256"
    }
}

struct CommonWriterSourceLock: Codable {
    let schemaVersion: String
    let artifactKind: String
    let sourceId: String
    let payloadPath: String
    let pixelLayout: CodecSourcePixelLayout
    let frameCount: Int
    let frames: [CommonWriterSourceFrame]
    let payloadSizeBytes: Int
    let payloadSha256: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case artifactKind = "artifact_kind"
        case sourceId = "source_id"
        case payloadPath = "payload_path"
        case pixelLayout = "pixel_layout"
        case frameCount = "frame_count"
        case frames
        case payloadSizeBytes = "payload_size_bytes"
        case payloadSha256 = "payload_sha256"
    }
}

struct CommonWriterSourceEvidence: Codable {
    let sourceId: String
    let payloadPath: String
    let payloadSha256: String
    let payloadSizeBytes: Int
    let sourceLockPath: String
    let sourceLockSha256: String
    let sourceLockSizeBytes: Int
    let pixelLayout: CodecSourcePixelLayout
    let frameCount: Int
    let frames: [CommonWriterSourceFrame]

    enum CodingKeys: String, CodingKey {
        case sourceId = "source_id"
        case payloadPath = "payload_path"
        case payloadSha256 = "payload_sha256"
        case payloadSizeBytes = "payload_size_bytes"
        case sourceLockPath = "source_lock_path"
        case sourceLockSha256 = "source_lock_sha256"
        case sourceLockSizeBytes = "source_lock_size_bytes"
        case pixelLayout = "pixel_layout"
        case frameCount = "frame_count"
        case frames
    }
}

struct CommonWriterEncodedEvidence: Codable {
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

struct CommonWriterDecodedFrame: Codable {
    let caseId: String
    let index: Int
    let presentationTime: ExactTime
    let duration: ExactTime
    let width: Int
    let height: Int
    let pixelFormat: String
    let payloadPath: String
    let payloadSizeBytes: Int
    let payloadSha256: String
    let activeRowSha256: PlaneHashes
    let attachments: AttachmentEvidence

    enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
        case index
        case presentationTime = "presentation_time"
        case duration, width, height
        case pixelFormat = "pixel_format"
        case payloadPath = "payload_path"
        case payloadSizeBytes = "payload_size_bytes"
        case payloadSha256 = "payload_sha256"
        case activeRowSha256 = "active_row_sha256"
        case attachments
    }
}

struct CommonWriterDecoderEvidence: Codable {
    let framework: String
    let sessionType: String
    let codec: String
    let pixelFormat: String
    let payloadLayout: String
    let frameCount: Int
    let frames: [CommonWriterDecodedFrame]

    enum CodingKeys: String, CodingKey {
        case framework
        case sessionType = "session_type"
        case codec
        case pixelFormat = "pixel_format"
        case payloadLayout = "payload_layout"
        case frameCount = "frame_count"
        case frames
    }
}

struct CommonWriterVerification: Codable {
    let sourceLockValid: Bool
    let sourceBytesMatchLock: Bool
    let encodedContainerReopened: Bool
    let actualCodecContainerUsed: Bool
    let exactCaseOrderPreserved: Bool
    let exactTimingPreserved: Bool
    let dimensionsPreserved: Bool
    let pixelFormatPreserved: Bool
    let attachmentsRecorded: Bool
    let rowPaddingExcluded: Bool
    let decodedPayloadsByteBound: Bool
    let frameCountPreserved: Bool

    enum CodingKeys: String, CodingKey {
        case sourceLockValid = "source_lock_valid"
        case sourceBytesMatchLock = "source_bytes_match_lock"
        case encodedContainerReopened = "encoded_container_reopened"
        case actualCodecContainerUsed = "actual_codec_container_used"
        case exactCaseOrderPreserved = "exact_case_order_preserved"
        case exactTimingPreserved = "exact_timing_preserved"
        case dimensionsPreserved = "dimensions_preserved"
        case pixelFormatPreserved = "pixel_format_preserved"
        case attachmentsRecorded = "attachments_recorded"
        case rowPaddingExcluded = "row_padding_excluded"
        case decodedPayloadsByteBound = "decoded_payloads_byte_bound"
        case frameCountPreserved = "frame_count_preserved"
    }
}

struct CommonWriterLimitations: Codable {
    let mp4ByteIdentityAcrossRunsClaimed: Bool
    let decodedPixelRepeatabilityScope: String
    let decoderAccelerationVisibility: String

    enum CodingKeys: String, CodingKey {
        case mp4ByteIdentityAcrossRunsClaimed = "mp4_byte_identity_across_runs_claimed"
        case decodedPixelRepeatabilityScope = "decoded_pixel_repeatability_scope"
        case decoderAccelerationVisibility = "decoder_acceleration_visibility"
    }
}

struct CommonWriterReport: Codable {
    let schemaVersion: String
    let artifactKind: String
    let status: String
    let source: CommonWriterSourceEvidence
    let encoded: CommonWriterEncodedEvidence
    let encoder: EncoderEvidence
    let decoder: CommonWriterDecoderEvidence
    let verification: CommonWriterVerification
    let environment: EnvironmentEvidence
    let limitations: CommonWriterLimitations

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case artifactKind = "artifact_kind"
        case status, source, encoded, encoder, decoder, verification, environment, limitations
    }
}

struct CommonWriterFailure: Codable {
    let schemaVersion = "1.0.0"
    let artifactKind = "common_writer_failure"
    let status = "fail"
    let errorType: String
    let message: String
    let sourcePath: String
    let sourceLockPath: String
    let requestedEncodedPath: String
    let requestedReportPath: String
    let requestedDecodedDirectory: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case artifactKind = "artifact_kind"
        case status
        case errorType = "error_type"
        case message
        case sourcePath = "source_path"
        case sourceLockPath = "source_lock_path"
        case requestedEncodedPath = "requested_encoded_path"
        case requestedReportPath = "requested_report_path"
        case requestedDecodedDirectory = "requested_decoded_directory"
    }
}
