import Foundation

struct ProductionWriterSourceBinding: Codable {
    let path: String
    let sha256: String
    let sizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case path, sha256
        case sizeBytes = "size_bytes"
    }
}

struct ProductionWriterEncoderEvidence: Codable {
    let framework: String
    let sessionType: String
    let requestedCodec: String
    let reopenedCodec: String
    let requestedAverageBitRate: Int
    let observedEstimatedDataRate: Double
    let expectedFrameRate: Int
    let expectsMediaDataInRealTime: Bool
    let pixelFormat: String
    let colorPrimaries: String
    let transferFunction: String
    let yCbCrMatrix: String
    let productSettingsSource: ProductionWriterSourceBinding

    enum CodingKeys: String, CodingKey {
        case framework
        case sessionType = "session_type"
        case requestedCodec = "requested_codec"
        case reopenedCodec = "reopened_codec"
        case requestedAverageBitRate = "requested_average_bit_rate"
        case observedEstimatedDataRate = "observed_estimated_data_rate"
        case expectedFrameRate = "expected_frame_rate"
        case expectsMediaDataInRealTime = "expects_media_data_in_real_time"
        case pixelFormat = "pixel_format"
        case colorPrimaries = "color_primaries"
        case transferFunction = "transfer_function"
        case yCbCrMatrix = "ycbcr_matrix"
        case productSettingsSource = "product_settings_source"
    }
}

struct ProductionWriterVerification: Codable {
    let sourceLockValid: Bool
    let sourceBytesMatchLock: Bool
    let productSettingsSourceBound: Bool
    let encodedContainerReopened: Bool
    let productionHEVCContainerUsed: Bool
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
        case productSettingsSourceBound = "product_settings_source_bound"
        case encodedContainerReopened = "encoded_container_reopened"
        case productionHEVCContainerUsed = "production_hevc_container_used"
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

struct ProductionWriterContainerScope: Codable {
    let frameCount: Int
    let singleFrameContainer: Bool
    let neighborFramesPresent: Bool
    let metricRole: String

    enum CodingKeys: String, CodingKey {
        case frameCount = "frame_count"
        case singleFrameContainer = "single_frame_container"
        case neighborFramesPresent = "neighbor_frames_present"
        case metricRole = "metric_role"
    }
}

struct ProductionWriterReport: Codable {
    let schemaVersion: String
    let artifactKind: String
    let status: String
    let source: CommonWriterSourceEvidence
    let encoded: CommonWriterEncodedEvidence
    let encoder: ProductionWriterEncoderEvidence
    let decoder: CommonWriterDecoderEvidence
    let containerScope: ProductionWriterContainerScope
    let verification: ProductionWriterVerification
    let environment: EnvironmentEvidence
    let limitations: CommonWriterLimitations

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case artifactKind = "artifact_kind"
        case status, source, encoded, encoder, decoder
        case containerScope = "container_scope"
        case verification, environment, limitations
    }
}
