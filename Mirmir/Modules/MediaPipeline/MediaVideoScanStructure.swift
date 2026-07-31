import CoreMedia
import Foundation

public enum MediaVideoScanStructure:
    String,
    CaseIterable,
    Codable,
    Equatable,
    Hashable,
    Sendable,
    CustomStringConvertible {
    case progressive
    case interlacedTopFieldFirst = "interlaced_top_field_first"
    case interlacedBottomFieldFirst = "interlaced_bottom_field_first"
    case interlacedSpatialFirstLineEarly =
        "interlaced_spatial_first_line_early"
    case interlacedSpatialFirstLineLate =
        "interlaced_spatial_first_line_late"
    case interlacedUnspecified = "interlaced_unspecified"

    public var description: String { rawValue }

    public var displayName: String {
        switch self {
        case .progressive:
            return "Progressive"
        case .interlacedTopFieldFirst:
            return "Interlaced · Top Field First"
        case .interlacedBottomFieldFirst:
            return "Interlaced · Bottom Field First"
        case .interlacedSpatialFirstLineEarly:
            return "Interlaced · First Line Early"
        case .interlacedSpatialFirstLineLate:
            return "Interlaced · First Line Late"
        case .interlacedUnspecified:
            return "Interlaced · Field Order Unspecified"
        }
    }

    public var requiresDeinterlacing: Bool {
        self != .progressive
    }
}

enum MediaVideoScanStructureResolver {
    static func resolve(
        _ formatDescriptions: [CMFormatDescription]
    ) throws -> MediaVideoScanStructure {
        guard !formatDescriptions.isEmpty else {
            throw MediaPipelineError.unsupportedVideoFormat(
                "the video track has no format description"
            )
        }
        var resolved: MediaVideoScanStructure?
        for description in formatDescriptions {
            let candidate = try resolve(description)
            if let resolved, resolved != candidate {
                throw MediaPipelineError.unsupportedVideoFormat(
                    "the video track changes scan structure within one track "
                        + "(\(resolved.rawValue) to "
                        + "\(candidate.rawValue))"
                )
            }
            resolved = candidate
        }
        return resolved ?? .progressive
    }

    private static func resolve(
        _ formatDescription: CMFormatDescription
    ) throws -> MediaVideoScanStructure {
        guard CMFormatDescriptionGetMediaType(formatDescription)
                == kCMMediaType_Video else {
            throw MediaPipelineError.unsupportedVideoFormat(
                "scan structure requires a video format description"
            )
        }
        let extensions = (
            CMFormatDescriptionGetExtensions(formatDescription)
                as NSDictionary?
        ) ?? [:]
        let fieldCount = (
            extensions[
                kCMFormatDescriptionExtension_FieldCount as String
            ] as? NSNumber
        )?.intValue ?? 1
        let fieldDetail = extensions[
            kCMFormatDescriptionExtension_FieldDetail as String
        ] as? String

        switch fieldCount {
        case 1:
            guard fieldDetail == nil else {
                throw MediaPipelineError.unsupportedVideoFormat(
                    "progressive video declares interlaced field detail "
                        + "\(fieldDetail ?? "missing")"
                )
            }
            return .progressive
        case 2:
            return try resolveInterlacedDetail(fieldDetail)
        default:
            throw MediaPipelineError.unsupportedVideoFormat(
                "video field count must be 1 or 2; observed "
                    + "\(fieldCount)"
            )
        }
    }

    private static func resolveInterlacedDetail(
        _ fieldDetail: String?
    ) throws -> MediaVideoScanStructure {
        guard let fieldDetail else {
            return .interlacedUnspecified
        }
        if fieldDetail
            == kCMFormatDescriptionFieldDetail_TemporalTopFirst
                as String {
            return .interlacedTopFieldFirst
        }
        if fieldDetail
            == kCMFormatDescriptionFieldDetail_TemporalBottomFirst
                as String {
            return .interlacedBottomFieldFirst
        }
        if fieldDetail
            == kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly
                as String {
            return .interlacedSpatialFirstLineEarly
        }
        if fieldDetail
            == kCMFormatDescriptionFieldDetail_SpatialFirstLineLate
                as String {
            return .interlacedSpatialFirstLineLate
        }
        throw MediaPipelineError.unsupportedVideoFormat(
            "unsupported interlaced field detail \(fieldDetail)"
        )
    }
}
