import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum AVCanonicalMediaAdmissionV4: String, Equatable, Sendable {
    case admitted
    case rejected
}

struct AVCanonicalMediaStateProbeV4: Equatable, Sendable {
    let state: CanonicalMediaStateV4
    let admission: AVCanonicalMediaAdmissionV4

    var blockingObservations: [CanonicalMediaObservationV4] {
        state.observations.filter {
            $0.severity == .error || $0.severity == .unsupported
        }
    }

    func requireAdmittedState() throws -> CanonicalMediaStateV4 {
        guard admission == .admitted else {
            throw AVCanonicalMediaStateAdapterV4Error
                .canonicalizationRejected(blockingObservations)
        }
        return state
    }
}

struct AVCanonicalMediaStateProbeRequestV4: Sendable {
    let url: URL
    let bookmarkReference: String
    let bookmarkDocumentSHA256: ASHSHA256V4
    let scanDynamicHDRMetadata: Bool

    init(
        url: URL,
        bookmarkReference: String,
        bookmarkDocumentSHA256: ASHSHA256V4,
        scanDynamicHDRMetadata: Bool = true
    ) {
        self.url = url
        self.bookmarkReference = bookmarkReference
        self.bookmarkDocumentSHA256 = bookmarkDocumentSHA256
        self.scanDynamicHDRMetadata = scanDynamicHDRMetadata
    }
}

/// Exact bridge from the eight-byte AVFoundation ambient-viewing payload into
/// the typed canonical color model. This is intentionally separate from the
/// generic property-list path so malformed or non-representable values fail
/// admission instead of being reduced to an opaque hash.
enum AVCanonicalAmbientViewingEnvironmentCodecV4 {
    static func decodeExtensionValue(
        _ value: Any?,
        path: String
    ) throws -> CanonicalAmbientViewingEnvironmentV4? {
        guard let value else { return nil }
        guard let data = value as? Data else {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: path,
                reason: "ambient viewing environment must be CFData"
            )
        }
        return try decode(data, path: path)
    }

    static func decode(
        _ data: Data,
        path: String
    ) throws -> CanonicalAmbientViewingEnvironmentV4 {
        let metadata: AmbientViewingEnvironmentV4
        do {
            metadata = try AmbientViewingEnvironmentV4(payload: data)
        } catch {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: path,
                reason: "invalid ambient viewing environment: \(error)"
            )
        }
        return CanonicalAmbientViewingEnvironmentV4(
            ambientIlluminance: try ExactRationalV4(
                Int64(metadata.ambientIlluminance),
                10_000
            ),
            ambientLightX: try ExactRationalV4(
                Int64(metadata.ambientLight.x),
                50_000
            ),
            ambientLightY: try ExactRationalV4(
                Int64(metadata.ambientLight.y),
                50_000
            )
        )
    }
}

enum AVCanonicalScanDescriptionV4Error: Error, Equatable, Sendable {
    case invalidFieldCount(Int?)
    case contradictoryProgressiveFieldDetail(String)
    case unsupportedFieldDetail(String?)
}

/// Canonical interpretation of the Core Media field-description contract.
/// A declared two-field format is a complete interlaced cadence declaration;
/// it does not require guessing cadence from decoded image content. Per-frame
/// discontinuities remain a temporal reset concern for the prepared backend.
struct AVCanonicalScanDescriptionV4: Equatable, Sendable {
    let state: CanonicalScanStateV4

    init(extensions: NSDictionary) throws {
        let declaredCount = (extensions[
            kCMFormatDescriptionExtension_FieldCount as String
        ] as? NSNumber)?.intValue
        let detail = extensions[
            kCMFormatDescriptionExtension_FieldDetail as String
        ] as? String

        switch declaredCount {
        case 1:
            if let detail {
                throw AVCanonicalScanDescriptionV4Error
                    .contradictoryProgressiveFieldDetail(detail)
            }
            state = CanonicalScanStateV4(
                fieldCount: 1,
                dominance: .none,
                cadence: .progressive
            )
        case 2:
            let dominance: CanonicalFieldDominanceV4
            if detail
                == kCMFormatDescriptionFieldDetail_TemporalTopFirst as String
                || detail
                == kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly as String {
                dominance = .topFieldFirst
            } else if detail
                == kCMFormatDescriptionFieldDetail_TemporalBottomFirst as String
                || detail
                == kCMFormatDescriptionFieldDetail_SpatialFirstLineLate as String {
                dominance = .bottomFieldFirst
            } else {
                throw AVCanonicalScanDescriptionV4Error
                    .unsupportedFieldDetail(detail)
            }
            state = CanonicalScanStateV4(
                fieldCount: 2,
                dominance: dominance,
                cadence: .interlaced
            )
        default:
            throw AVCanonicalScanDescriptionV4Error
                .invalidFieldCount(declaredCount)
        }
    }
}

/// AVFoundation observation boundary for deterministic engine v4. Every value
/// crossing this boundary is copied into an immutable Foundation-only record.
/// The track array is never filtered or re-sorted: ordinals are the exact
/// order returned by `asset.load(.tracks)`.
struct AVCanonicalMediaStateAdapterV4: Sendable {
    func probe(
        _ request: AVCanonicalMediaStateProbeRequestV4
    ) async throws -> AVCanonicalMediaStateProbeV4 {
        let fileIdentity = try ASHStreamingFileIdentityV4.read(url: request.url)
        let asset = try await NativeMediaInputAssetResolverV4.asset(
            url: request.url, sourceIdentity: fileIdentity
        )
        if let original = OriginalSoftwareMediaContext.associated(with: asset) {
            return try original.canonicalProbe(
                request: request, fileIdentity: fileIdentity
            )
        }
        let assetTracks: [AVAssetTrack]
        do {
            assetTracks = try await asset.load(.tracks)
        } catch {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: "asset.tracks",
                reason: String(describing: error)
            )
        }
        try Task.checkCancellation()

        var tracks: [CanonicalMediaTrackV4] = []
        var observations: [CanonicalMediaObservationV4] = []
        let associationProbe = try await probeAssociations(assetTracks)
        observations.append(contentsOf: associationProbe.observations)
        let trackIDCounts = Dictionary(
            grouping: assetTracks.map(\.trackID),
            by: { $0 }
        ).mapValues(\.count)
        tracks.reserveCapacity(assetTracks.count + 2)
        for (ordinal, track) in assetTracks.enumerated() {
            let trackID = track.trackID
            let hasUsableContainerID = trackID != 0
                && trackIDCounts[trackID] == 1
            if !hasUsableContainerID {
                observations.append(
                    observation(
                        severity: .error,
                        code: .contradictory,
                        path: String(format: "tracks[%06d].track_id", ordinal),
                        value: trackID == 0
                            ? "zero container track ID"
                            : "duplicate container track ID \(trackID)"
                    )
                )
            }
            let persistentID = hasUsableContainerID
                ? "asset-track-\(trackID)"
                : "asset-track-\(trackID)-ordinal-\(ordinal)"
            let result = await probeTrack(
                track,
                ordinal: UInt32(ordinal),
                persistentID: persistentID,
                isChapter: associationProbe.chapterOrdinals.contains(ordinal),
                associationMetadata:
                    associationProbe.metadataBySourceOrdinal[ordinal] ?? [],
                asset: asset,
                scanDynamicHDRMetadata: request.scanDynamicHDRMetadata
            )
            observations.append(contentsOf: result.observations)
            if let track = result.track {
                tracks.append(track)
            }
        }

        let virtual = await probeAssetMetadataTracks(
            asset,
            startingOrdinal: UInt32(assetTracks.count)
        )
        observations.append(contentsOf: virtual.observations)
        tracks.append(contentsOf: virtual.tracks)

        try fileIdentity.verifyUnchanged(url: request.url)

        guard tracks.count == assetTracks.count + virtual.tracks.count else {
            throw AVCanonicalMediaStateAdapterV4Error.canonicalizationRejected(
                observations.sorted()
            )
        }
        let state: CanonicalMediaStateV4
        do {
            state = try CanonicalMediaStateV4(
                input: CanonicalInputIdentityV4(
                    contentSHA256: fileIdentity.contentSHA256,
                    byteCount: fileIdentity.byteCount,
                    fileName: request.url.lastPathComponent,
                    bookmarkReference: request.bookmarkReference,
                    bookmarkDocumentSHA256: request.bookmarkDocumentSHA256
                ),
                tracks: tracks,
                observations: observations.sorted()
            )
        } catch {
            observations.append(
                observation(
                    severity: .error,
                    code: .malformed,
                    path: "canonical_media_state",
                    value: String(describing: error)
                )
            )
            throw AVCanonicalMediaStateAdapterV4Error.canonicalizationRejected(
                observations.sorted()
            )
        }
        let admission: AVCanonicalMediaAdmissionV4 = state.observations.contains {
            $0.severity == .error || $0.severity == .unsupported
        } ? .rejected : .admitted
        return AVCanonicalMediaStateProbeV4(
            state: state,
            admission: admission
        )
    }
}

private extension AVCanonicalMediaStateAdapterV4 {
    struct TrackProbeResult {
        let track: CanonicalMediaTrackV4?
        let observations: [CanonicalMediaObservationV4]
    }

    struct VirtualTrackProbeResult {
        let tracks: [CanonicalMediaTrackV4]
        let observations: [CanonicalMediaObservationV4]
    }

    struct AssociationProbeResult {
        let chapterOrdinals: Set<Int>
        let metadataBySourceOrdinal: [Int: [CanonicalMetadataValueV4]]
        let observations: [CanonicalMediaObservationV4]
    }

    func probeAssociations(
        _ tracks: [AVAssetTrack]
    ) async throws -> AssociationProbeResult {
        let ordinalsByTrackID = Dictionary(
            grouping: tracks.indices,
            by: { tracks[$0].trackID }
        )
        var chapterOrdinals = Set<Int>()
        var metadataBySourceOrdinal: [Int: [CanonicalMetadataValueV4]] = [:]
        var observations: [CanonicalMediaObservationV4] = []
        for (sourceOrdinal, track) in tracks.enumerated() {
            let types = try await track.load(.availableTrackAssociationTypes)
                .sorted { $0.rawValue < $1.rawValue }
            var associationOrdinal = 0
            for type in types {
                let associated = try await track.loadAssociatedTracks(ofType: type)
                let resolved = associated.compactMap { target -> Int? in
                    guard let candidates = ordinalsByTrackID[target.trackID],
                          candidates.count == 1 else { return nil }
                    return candidates[0]
                }.sorted()
                if resolved.count != associated.count {
                    observations.append(
                        observation(
                            severity: .error,
                            code: .contradictory,
                            path: "tracks[\(sourceOrdinal)].associations",
                            value: "unresolved or ambiguous associated track"
                        )
                    )
                }
                for targetOrdinal in resolved {
                    if type == .chapterList {
                        chapterOrdinals.insert(targetOrdinal)
                    }
                    let data = try ASHCanonicalPropertyListV4.data(
                        [
                            "source_ordinal": NSNumber(value: sourceOrdinal),
                            "target_ordinal": NSNumber(value: targetOrdinal),
                            "association_type": type.rawValue
                        ],
                        path: "tracks[\(sourceOrdinal)].associations[\(associationOrdinal)]"
                    )
                    metadataBySourceOrdinal[sourceOrdinal, default: []].append(
                        CanonicalMetadataValueV4(
                            key: String(
                                format: "association-%06d",
                                associationOrdinal
                            ),
                            dataType:
                                "application/vnd.apple.track-association.v4",
                            locale: nil,
                            valueSHA256: ASHSHA256V4(rawData: data)
                        )
                    )
                    associationOrdinal += 1
                }
            }
        }
        return AssociationProbeResult(
            chapterOrdinals: chapterOrdinals,
            metadataBySourceOrdinal: metadataBySourceOrdinal,
            observations: observations.sorted()
        )
    }

    struct VideoFormatFacts: Equatable {
        let encodedRaster: CanonicalRasterV4
        let cleanApertureSpecification: CleanApertureV4
        let cleanAperture: CanonicalRationalRectV4?
        let pixelAspectRatio: ExactRationalV4
        let pixel: CanonicalPixelStateV4
        let color: CanonicalColorStateV4
        let scan: CanonicalScanStateV4
        let sourceBottomChromaSiting: CanonicalChromaSitingV4?
    }

    func probeTrack(
        _ track: AVAssetTrack,
        ordinal: UInt32,
        persistentID: String,
        isChapter: Bool,
        associationMetadata: [CanonicalMetadataValueV4],
        asset: AVAsset,
        scanDynamicHDRMetadata: Bool
    ) async -> TrackProbeResult {
        let root = String(format: "tracks[%06u]", ordinal)
        var observations: [CanonicalMediaObservationV4] = []
        do {
            let enabled = try await track.load(.isEnabled)
            let timeRange = try await track.load(.timeRange)
            let naturalTimeScale = try await track.load(.naturalTimeScale)
            let formatDescriptions = try await track.load(.formatDescriptions)
            let characteristics = try await track.load(.mediaCharacteristics)
            let segments = try await track.load(.segments)
            let metadataItems = try await track.load(.metadata)
            let extendedLanguageTag = try await track.load(.extendedLanguageTag)
            let languageCode = try await track.load(.languageCode)
            try Task.checkCancellation()

            let formatMetadata = try formatDescriptionMetadata(
                formatDescriptions,
                root: root,
                observations: &observations
            )
            let itemMetadata = try await canonicalMetadata(
                metadataItems,
                keyPrefix: "metadata",
                root: root,
                observations: &observations
            )
            let kind = classify(
                mediaType: track.mediaType,
                metadata: metadataItems,
                isChapter: isChapter
            )
            if kind == .unknown {
                observations.append(
                    observation(
                        severity: .unsupported,
                        code: .unknownValue,
                        path: "\(root).media_type",
                        value: track.mediaType.rawValue
                    )
                )
            }
            let codecIDs = formatDescriptions.map {
                fourCC(CMFormatDescriptionGetMediaSubType($0))
            }
            let distinctCodecs = Set(codecIDs)
            let codecID: String
            if distinctCodecs.count == 1, let only = distinctCodecs.first {
                codecID = only
            } else if distinctCodecs.isEmpty {
                codecID = "unknown"
                observations.append(
                    observation(
                        severity: .warning,
                        code: .missingRequiredValue,
                        path: "\(root).codec",
                        value: "no format descriptions"
                    )
                )
            } else {
                codecID = codecIDs[0]
                observations.append(
                    observation(
                        severity: .error,
                        code: .contradictory,
                        path: "\(root).codec",
                        value: codecIDs.joined(separator: ",")
                    )
                )
            }

            let edits = try canonicalEdits(
                segments,
                root: root,
                observations: &observations
            )
            let duration = try ASHExactCMTimeV4.convert(
                timeRange.duration,
                path: "\(root).duration"
            )
            guard naturalTimeScale > 0 else {
                throw AVCanonicalMediaStateAdapterV4Error.nonPositiveTimeScale(
                    path: "\(root).natural_time_scale",
                    value: naturalTimeScale
                )
            }
            let timebase = try ExactRationalV4(1, Int64(naturalTimeScale))
            let video: CanonicalVideoStateV4?
            var dynamicMetadata: [CanonicalDynamicHDRMetadataV4] = []
            if kind == .video {
                let preferredTransform = try await track.load(.preferredTransform)
                let proResFacts = try ProRes422SourceFactsV4.resolve(
                    asset: asset, track: track, descriptions: formatDescriptions)
                let nativeDecodedColor = try VideoDecodedColorResolver.resolve(
                    asset: asset,
                    track: track,
                    descriptions: formatDescriptions
                )
                let decodedColor = proResFacts?.colorFallback(over: nativeDecodedColor) ?? nativeDecodedColor
                let legacySampling = try LegacyVideoSamplingFacts.resolve(
                    asset: asset, track: track, descriptions: formatDescriptions
                )
                let facts = try consistentVideoFacts(
                    formatDescriptions,
                    characteristics: characteristics,
                    decodedColor: decodedColor,
                    legacySampling: legacySampling,
                    proResFacts: proResFacts,
                    root: root,
                    observations: &observations
                )
                if scanDynamicHDRMetadata {
                    dynamicMetadata = try scanDynamicHDR(
                        asset: asset,
                        track: track,
                        root: root
                    )
                } else {
                    observations.append(
                        observation(
                            severity: .unsupported,
                            code: .missingRequiredValue,
                            path: "\(root).dynamic_hdr_metadata",
                            value: "dynamic HDR scan disabled"
                        )
                    )
                }
                let transform = try affineTransform(
                    preferredTransform,
                    path: "\(root).preferred_transform"
                )
                let presentationRaster = try presentationRaster(
                    facts: facts,
                    transform: transform,
                    path: "\(root).presentation_raster"
                )
                let color = CanonicalColorStateV4(
                    primaries: facts.color.primaries,
                    transferFunction: facts.color.transferFunction,
                    matrix: facts.color.matrix,
                    masteringDisplay: facts.color.masteringDisplay,
                    contentLightLevel: facts.color.contentLightLevel,
                    ambientViewingEnvironment:
                        facts.color.ambientViewingEnvironment,
                    dynamicHDRMetadata: dynamicMetadata
                )
                video = CanonicalVideoStateV4(
                    encodedRaster: facts.encodedRaster,
                    presentationRaster: presentationRaster,
                    preferredTransform: transform,
                    cleanAperture: facts.cleanAperture,
                    pixelAspectRatio: facts.pixelAspectRatio,
                    pixel: facts.pixel,
                    color: color,
                    scan: facts.scan
                )
            } else {
                video = nil
            }

            let roles = Array(Set(characteristics.map(\.rawValue))).sorted()
            let segmentMetadata = try canonicalSegmentMetadata(
                segments,
                root: root
            )
            let metadata = (
                formatMetadata
                    + itemMetadata
                    + segmentMetadata
                    + associationMetadata
            ).sorted {
                $0.key < $1.key
            }
            return TrackProbeResult(
                track: CanonicalMediaTrackV4(
                    identity: CanonicalTrackIdentityV4(
                        ordinal: ordinal,
                        persistentID: persistentID
                    ),
                    enabled: enabled,
                    kind: kind,
                    languageTag: extendedLanguageTag ?? languageCode,
                    roleIDs: roles,
                    codecID: codecID,
                    timebase: timebase,
                    duration: duration,
                    edits: edits,
                    metadata: metadata,
                    video: video
                ),
                observations: observations.sorted()
            )
        } catch is CancellationError {
            return TrackProbeResult(
                track: nil,
                observations: observations + [
                    observation(
                        severity: .error,
                        code: .malformed,
                        path: root,
                        value: "cancelled"
                    )
                ]
            )
        } catch {
            observations.append(
                observation(
                    severity: .error,
                    code: .malformed,
                    path: root,
                    value: String(describing: error)
                )
            )
            return TrackProbeResult(
                track: nil,
                observations: observations.sorted()
            )
        }
    }

    func consistentVideoFacts(
        _ descriptions: [CMFormatDescription],
        characteristics: [AVMediaCharacteristic],
        decodedColor: [String: String],
        legacySampling: LegacyVideoSamplingFacts?,
        proResFacts: ProRes422SourceFactsV4? = nil,
        root: String,
        observations: inout [CanonicalMediaObservationV4]
    ) throws -> VideoFormatFacts {
        guard !descriptions.isEmpty else {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: "\(root).format_descriptions",
                reason: "video track has no format description"
            )
        }
        let facts = try descriptions.enumerated().map { index, description in
            try videoFacts(
                description,
                characteristics: characteristics,
                decodedColor: decodedColor,
                legacySampling: legacySampling,
                proResFacts: proResFacts,
                root: "\(root).format_descriptions[\(index)]",
                observations: &observations
            )
        }
        guard facts.dropFirst().allSatisfy({ $0 == facts[0] }) else {
            observations.append(
                observation(
                    severity: .error,
                    code: .contradictory,
                    path: "\(root).format_descriptions",
                    value: "video semantics change within one track"
                )
            )
            return facts[0]
        }
        return facts[0]
    }

    func videoFacts(
        _ description: CMFormatDescription,
        characteristics: [AVMediaCharacteristic],
        decodedColor: [String: String],
        legacySampling: LegacyVideoSamplingFacts?,
        proResFacts: ProRes422SourceFactsV4? = nil,
        root: String,
        observations: inout [CanonicalMediaObservationV4]
    ) throws -> VideoFormatFacts {
        guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video
        else {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: root,
                reason: "non-video format description on video track"
            )
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0, dimensions.height > 0 else {
            throw AVCanonicalMediaStateAdapterV4Error.nonFiniteGeometry(
                path: "\(root).encoded_raster"
            )
        }
        let extensions = (
            CMFormatDescriptionGetExtensions(description) as NSDictionary?
        ) ?? [:]
        let cleanAperture = try cleanAperture(
            extensions,
            codedWidth: Int64(dimensions.width),
            codedHeight: Int64(dimensions.height),
            root: root
        )
        let sampleAspectRatio = try pixelAspectRatio(
            extensions,
            root: root,
            observations: &observations
        )
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        if let legacySampling {
            let declaredDepth = extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber
            let declaredRange = extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] as? NSNumber
            guard declaredDepth == nil || declaredDepth?.intValue == Int(legacySampling.bitDepth),
                  declaredRange == nil || declaredRange?.boolValue == legacySampling.fullRange else {
                throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                    path: "\(root).pixel", reason: "Legacy bitstream and container sampling declarations disagree."
                )
            }
        }
        let bitDepth = try legacySampling?.bitDepth ?? bitDepth(
            description,
            extensions: extensions,
            root: root,
            observations: &observations
        )
        let subsampling = legacySampling?.subsampling ?? chromaSubsampling(
            description: description,
            subtype: subtype,
            extensions: extensions,
            root: root,
            observations: &observations
        )
        let range = legacySampling.map { $0.fullRange ? CanonicalPixelRangeV4.full : .video } ?? pixelRange(
            extensions,
            subsampling: subsampling,
            root: root,
            observations: &observations
        )
        let fieldChromaSiting = try fieldChromaSiting(
            description: description, extensions: extensions, subsampling: subsampling
        )
        let siting = try legacySampling?.jfifDeclaration.map { _ in
            CanonicalChromaSitingV4.center
        } ?? chromaSiting(
            description: description,
            extensions,
            subsampling: subsampling,
            subtype: subtype,
            decodedLegacySampling: legacySampling != nil,
            root: root,
            observations: &observations
        )
        let alpha = alphaModel(
            extensions,
            subtype: subtype,
            root: root,
            observations: &observations
        )
        let color = try colorState(
            extensions,
            decodedColor: decodedColor,
            root: root,
            observations: &observations
        )
        let scanExtensions = extensions.mutableCopy() as! NSMutableDictionary
        if legacySampling != nil, subtype == kCMVideoCodecType_MPEG4Video,
           scanExtensions[kCMFormatDescriptionExtension_FieldCount as String] == nil {
            // The admitted VOL parser verifies its interlaced flag is zero.
            scanExtensions[kCMFormatDescriptionExtension_FieldCount as String] = NSNumber(value: 1)
        }
        if let proResFacts {
            if scanExtensions[kCMFormatDescriptionExtension_FieldCount as String] == nil {
                scanExtensions[kCMFormatDescriptionExtension_FieldCount as String] = NSNumber(value: proResFacts.scan.fieldCount)
            }
            if let detail = proResFacts.scan.fieldDetail,
               scanExtensions[kCMFormatDescriptionExtension_FieldDetail as String] == nil {
                scanExtensions[kCMFormatDescriptionExtension_FieldDetail as String] = detail
            }
        }
        let scan = scanState(
            scanExtensions,
            root: root,
            observations: &observations
        )
        return VideoFormatFacts(
            encodedRaster: CanonicalRasterV4(
                width: Int64(dimensions.width),
                height: Int64(dimensions.height)
            ),
            cleanApertureSpecification: cleanAperture.specification,
            cleanAperture: cleanAperture.canonicalRect,
            pixelAspectRatio: sampleAspectRatio,
            pixel: CanonicalPixelStateV4(
                formatID: "encoded-\(fourCC(subtype))",
                bitDepth: bitDepth,
                range: range,
                chromaSubsampling: subsampling,
                chromaSiting: siting,
                alphaModel: alpha,
                fieldChromaSiting: fieldChromaSiting
            ),
            color: color,
            scan: scan,
            sourceBottomChromaSiting: try AVCChromaLocationV4.declaration(from: description)?.bottomLocation
                ?? AVCChromaLocationV4.canonicalLocation(
                    extensions[kCMFormatDescriptionExtension_ChromaLocationBottomField as String] as? String
                )
        )
    }

    func affineTransform(
        _ value: CGAffineTransform,
        path: String
    ) throws -> CanonicalAffineTransformV4 {
        try CanonicalAffineTransformV4(
            a: ASHExactBinaryRationalV4.convert(value.a, path: "\(path).a"),
            b: ASHExactBinaryRationalV4.convert(value.b, path: "\(path).b"),
            c: ASHExactBinaryRationalV4.convert(value.c, path: "\(path).c"),
            d: ASHExactBinaryRationalV4.convert(value.d, path: "\(path).d"),
            tx: ASHExactBinaryRationalV4.convert(value.tx, path: "\(path).tx"),
            ty: ASHExactBinaryRationalV4.convert(value.ty, path: "\(path).ty")
        )
    }

    func presentationRaster(
        facts: VideoFormatFacts,
        transform: CanonicalAffineTransformV4,
        path: String
    ) throws -> CanonicalRasterV4 {
        let geometry = try RationalPresentationGeometryV4(
            codedWidth: facts.encodedRaster.width,
            codedHeight: facts.encodedRaster.height,
            cleanAperture: facts.cleanApertureSpecification,
            sampleAspectRatio: try SampleAspectRatioV4(
                horizontalSpacing: facts.pixelAspectRatio.numerator,
                verticalSpacing: facts.pixelAspectRatio.denominator
            ),
            preferredTransform: RationalAffineTransformV4(
                a: transform.a,
                b: transform.b,
                c: transform.c,
                d: transform.d,
                tx: transform.tx,
                ty: transform.ty
            )
        )
        let bounds = try geometry.presentationBounds()
        guard let width = bounds.size.width.integerValue,
              let height = bounds.size.height.integerValue,
              width > 0,
              height > 0 else {
            throw AVCanonicalMediaStateAdapterV4Error
                .geometryOutsideExactRationalDomain(path: path)
        }
        return CanonicalRasterV4(width: width, height: height)
    }

    struct ExtractedCleanAperture: Equatable {
        let specification: CleanApertureV4
        let canonicalRect: CanonicalRationalRectV4?
    }

    func cleanAperture(
        _ extensions: NSDictionary,
        codedWidth: Int64,
        codedHeight: Int64,
        root: String
    ) throws -> ExtractedCleanAperture {
        guard let dictionary = extensions[
            kCMFormatDescriptionExtension_CleanAperture as String
        ] as? NSDictionary else {
            return ExtractedCleanAperture(
                specification: try .fullRaster(
                    width: codedWidth,
                    height: codedHeight
                ),
                canonicalRect: nil
            )
        }
        let width = try apertureValue(
            dictionary,
            rationalKey: kCMFormatDescriptionKey_CleanApertureWidthRational,
            scalarKey: kCMFormatDescriptionKey_CleanApertureWidth,
            path: "\(root).clean_aperture.width"
        )
        let height = try apertureValue(
            dictionary,
            rationalKey: kCMFormatDescriptionKey_CleanApertureHeightRational,
            scalarKey: kCMFormatDescriptionKey_CleanApertureHeight,
            path: "\(root).clean_aperture.height"
        )
        let horizontalOffset = try apertureValue(
            dictionary,
            rationalKey:
                kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational,
            scalarKey: kCMFormatDescriptionKey_CleanApertureHorizontalOffset,
            path: "\(root).clean_aperture.horizontal_offset"
        )
        let verticalOffset = try apertureValue(
            dictionary,
            rationalKey:
                kCMFormatDescriptionKey_CleanApertureVerticalOffsetRational,
            scalarKey: kCMFormatDescriptionKey_CleanApertureVerticalOffset,
            path: "\(root).clean_aperture.vertical_offset"
        )
        let aperture = try CleanApertureV4(
            width: width,
            height: height,
            horizontalOffset: horizontalOffset,
            verticalOffset: verticalOffset
        )
        let rect = try aperture.rect(
            codedWidth: codedWidth,
            codedHeight: codedHeight
        )
        return ExtractedCleanAperture(
            specification: aperture,
            canonicalRect: CanonicalRationalRectV4(
                origin: CanonicalRationalPointV4(
                    x: rect.origin.x,
                    y: rect.origin.y
                ),
                size: CanonicalRationalSizeV4(
                    width: rect.size.width,
                    height: rect.size.height
                )
            )
        )
    }

    func apertureValue(
        _ dictionary: NSDictionary,
        rationalKey: CFString,
        scalarKey: CFString,
        path: String
    ) throws -> ExactRationalV4 {
        if let pair = dictionary[rationalKey as String] as? [NSNumber],
           pair.count == 2 {
            return try ExactRationalV4(
                exactInteger(pair[0], path: "\(path).numerator"),
                exactInteger(pair[1], path: "\(path).denominator")
            )
        }
        guard let scalar = dictionary[scalarKey as String] as? NSNumber else {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: path,
                reason: "clean-aperture scalar and rational values are absent"
            )
        }
        return try rational(number: scalar, path: path)
    }

    func pixelAspectRatio(
        _ extensions: NSDictionary,
        root: String,
        observations: inout [CanonicalMediaObservationV4]
    ) throws -> ExactRationalV4 {
        guard let dictionary = extensions[
            kCMFormatDescriptionExtension_PixelAspectRatio as String
        ] as? NSDictionary else {
            // Core Media defines omission as square samples.
            return .one
        }
        guard let horizontal = dictionary[
            kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String
        ] as? NSNumber,
              let vertical = dictionary[
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String
              ] as? NSNumber else {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: "\(root).pixel_aspect_ratio",
                reason: "incomplete pixel-aspect-ratio dictionary"
            )
        }
        return try ExactRationalV4(
            exactInteger(horizontal, path: "\(root).pixel_aspect_ratio.h"),
            exactInteger(vertical, path: "\(root).pixel_aspect_ratio.v")
        )
    }

    func bitDepth(
        _ description: CMFormatDescription,
        extensions: NSDictionary,
        root: String,
        observations: inout [CanonicalMediaObservationV4]
    ) throws -> UInt8 {
        if let number = extensions[
            kCMFormatDescriptionExtension_BitsPerComponent as String
        ] as? NSNumber {
            let value = try exactInteger(number, path: "\(root).bit_depth")
            guard (1...16).contains(value) else {
                throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                    path: "\(root).bit_depth",
                    reason: "out of range: \(value)"
                )
            }
            return UInt8(value)
        }
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let known: [FourCharCode: UInt8] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: 8,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: 8,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: 10,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: 10,
            FourCharCode(bitPattern: Int32(bigEndianASCII("apch"))): 10,
            FourCharCode(bitPattern: Int32(bigEndianASCII("apcn"))): 10,
            FourCharCode(bitPattern: Int32(bigEndianASCII("apcs"))): 10,
            FourCharCode(bitPattern: Int32(bigEndianASCII("apco"))): 10,
            FourCharCode(bitPattern: Int32(bigEndianASCII("ap4h"))): 12,
            FourCharCode(bitPattern: Int32(bigEndianASCII("ap4x"))): 12
        ]
        if let bitDepth = known[subtype] { return bitDepth }
        if subtype == kCMVideoCodecType_H264,
           let semantics = h264Semantics(description) {
            return semantics.bitDepth
        }
        if [kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha,
            kCMVideoCodecType_DolbyVisionHEVC].contains(subtype),
           let semantics = hevcSemantics(extensions) {
            return semantics.bitDepth
        }
        observations.append(
            observation(
                severity: .error,
                code: .unknownValue,
                path: "\(root).bit_depth",
                value: "not derivable from \(fourCC(subtype))"
            )
        )
        // A video state cannot encode an unknown bit depth. This value is only
        // a structural placeholder; the error observation rejects admission.
        return 8
    }

    struct CodecSamplingSemantics {
        let bitDepth: UInt8
        let subsampling: CanonicalChromaSubsamplingV4
    }

    func chromaSubsampling(
        description: CMFormatDescription,
        subtype: FourCharCode,
        extensions: NSDictionary,
        root: String,
        observations: inout [CanonicalMediaObservationV4]
    ) -> CanonicalChromaSubsamplingV4 {
        if [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        ].contains(subtype) {
            return .yuv420
        }
        let code = fourCC(subtype)
        if ["fourcc-61703468", "fourcc-61703478"].contains(code) {
            return .yuv444
        }
        if ["fourcc-61706368", "fourcc-6170636e", "fourcc-61706373",
            "fourcc-6170636f"].contains(code) {
            return .yuv422
        }
        if subtype == kCMVideoCodecType_H264,
           let semantics = h264Semantics(description) {
            return semantics.subsampling
        }
        if [kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha,
            kCMVideoCodecType_DolbyVisionHEVC].contains(subtype),
           let semantics = hevcSemantics(extensions) {
            return semantics.subsampling
        }
        observations.append(
            observation(
                severity: .unsupported,
                code: .unknownValue,
                path: "\(root).chroma_subsampling",
                value: fourCC(subtype)
            )
        )
        return .unknown
    }

    func pixelRange(
        _ extensions: NSDictionary,
        subsampling: CanonicalChromaSubsamplingV4,
        root: String,
        observations: inout [CanonicalMediaObservationV4]
    ) -> CanonicalPixelRangeV4 {
        if let value = extensions[
            kCMFormatDescriptionExtension_FullRangeVideo as String
        ] as? NSNumber {
            return value.boolValue ? .full : .video
        }
        if subsampling == .rgb { return .full }
        // Core Media documents video range as the default for compressed YCbCr.
        if [.yuv420, .yuv422, .yuv444, .monochrome].contains(subsampling) {
            return .video
        }
        observations.append(
            observation(
                severity: .unsupported,
                code: .unknownValue,
                path: "\(root).pixel_range",
                value: "no full-range declaration"
            )
        )
        return .unknown
    }

    func fieldChromaSiting(
        description: CMFormatDescription,
        extensions: NSDictionary,
        subsampling: CanonicalChromaSubsamplingV4
    ) throws -> CanonicalFieldChromaSitingV4? {
        guard subsampling == .yuv420,
              (extensions[kCMFormatDescriptionExtension_FieldCount as String] as? NSNumber)?.intValue == 2 else {
            return nil
        }
        let declaration = try AVCChromaLocationV4.declaration(from: description)
        let top = declaration?.location ?? AVCChromaLocationV4.canonicalLocation(
            extensions[kCMFormatDescriptionExtension_ChromaLocationTopField as String] as? String)
        let bottom = declaration?.bottomLocation ?? AVCChromaLocationV4.canonicalLocation(
            extensions[kCMFormatDescriptionExtension_ChromaLocationBottomField as String] as? String)
        guard let top, let bottom, top != bottom else { return nil }
        let pair = CanonicalFieldChromaSitingV4(top: top, bottom: bottom)
        return pair.isValid ? pair : nil
    }

    func chromaSiting(
        description: CMFormatDescription,
        _ extensions: NSDictionary,
        subsampling: CanonicalChromaSubsamplingV4,
        subtype: FourCharCode,
        decodedLegacySampling: Bool = false,
        root: String,
        observations: inout [CanonicalMediaObservationV4]
    ) throws -> CanonicalChromaSitingV4 {
        if try MPEG4ProgressiveSamplingV4.declaration(from: description) != nil {
            return .left
        }
        if let pair = try fieldChromaSiting(description: description,
            extensions: extensions, subsampling: subsampling) {
            observations.append(observation(severity: .information, code: .unsupportedValue,
                path: "\(root).field_chroma_siting",
                value: "top=\(pair.top.rawValue),bottom=\(pair.bottom.rawValue)"))
            return .unknown
        }
        if let declared = try AVCChromaLocationV4.declaration(from: description) {
            return declared.location
        }
        if subtype == kCMVideoCodecType_H264, subsampling == .yuv420 {
            observations.append(observation(
                severity: .unsupported, code: .unknownValue,
                path: "\(root).chroma_siting", value: "avc_sps_unavailable"
            ))
            return .unknown
        }
        if subsampling == .rgb
            || subsampling == .monochrome
            || subsampling == .yuv444 {
            return .notApplicable
        }
        let top = extensions[
            kCMFormatDescriptionExtension_ChromaLocationTopField as String
        ] as? String
        let bottom = extensions[
            kCMFormatDescriptionExtension_ChromaLocationBottomField as String
        ] as? String
        if let top, let bottom, top != bottom {
            observations.append(
                observation(
                    severity: .error,
                    code: .contradictory,
                    path: "\(root).chroma_siting",
                    value: "top=\(top),bottom=\(bottom)"
                )
            )
            return .unknown
        }
        guard let value = top ?? bottom else {
            // ProRes 422 is decoded by AVFoundation into the declared P010
            // processing surface. Retain its absent source tag as unknown;
            // do not invent a location that the source did not declare.
            let proRes422 = [
                kCMVideoCodecType_AppleProRes422,
                kCMVideoCodecType_AppleProRes422HQ,
                kCMVideoCodecType_AppleProRes422LT,
                kCMVideoCodecType_AppleProRes422Proxy
            ].contains(subtype)
            observations.append(
                observation(
                    severity: proRes422 || decodedLegacySampling ? .warning : .unsupported,
                    code: .unknownValue,
                    path: "\(root).chroma_siting",
                    value: "absent"
                )
            )
            return .unknown
        }
        if value == kCMFormatDescriptionChromaLocation_Left as String {
            return .left
        }
        if value == kCMFormatDescriptionChromaLocation_Center as String {
            return .center
        }
        if value == kCMFormatDescriptionChromaLocation_TopLeft as String {
            return .topLeft
        }
        if value == kCMFormatDescriptionChromaLocation_Top as String {
            return .top
        }
        if value == kCMFormatDescriptionChromaLocation_BottomLeft as String {
            return .bottomLeft
        }
        if value == kCMFormatDescriptionChromaLocation_Bottom as String {
            return .bottom
        }
        observations.append(
            observation(
                severity: .unsupported,
                code: .unknownValue,
                path: "\(root).chroma_siting",
                value: value
            )
        )
        return .unknown
    }

    func alphaModel(
        _ extensions: NSDictionary,
        subtype: FourCharCode,
        root: String,
        observations: inout [CanonicalMediaObservationV4]
    ) -> CanonicalAlphaModelV4 {
        let containsAlpha = (extensions[
            kCMFormatDescriptionExtension_ContainsAlphaChannel as String
        ] as? NSNumber)?.boolValue ?? (subtype == kCMVideoCodecType_HEVCWithAlpha)
        let mode = extensions[
            kCMFormatDescriptionExtension_AlphaChannelMode as String
        ] as? String
        guard containsAlpha || mode != nil else { return .none }
        if mode == kCMFormatDescriptionAlphaChannelMode_StraightAlpha as String {
            return .straight
        }
        if mode
            == kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha as String {
            return .premultiplied
        }
        observations.append(
            observation(
                severity: .unsupported,
                code: .unknownValue,
                path: "\(root).alpha_model",
                value: mode ?? "contains alpha without association"
            )
        )
        return .unknown
    }

    func colorState(
        _ extensions: NSDictionary,
        decodedColor: [String: String],
        root: String,
        observations: inout [CanonicalMediaObservationV4]
    ) throws -> CanonicalColorStateV4 {
        func colorString(_ key: CFString, name: String) -> String {
            if let value = extensions[key as String] as? String { return value }
            if let value = decodedColor[key as String] {
                observations.append(observation(
                    severity: .warning,
                    code: .missingRequiredValue,
                    path: "\(root).color.\(name)",
                    value: "absent; decoder resolved \(value)"
                ))
                return value
            }
            observations.append(
                observation(
                    severity: .unsupported,
                    code: .unknownValue,
                    path: "\(root).color.\(name)",
                    value: "absent"
                )
            )
            return "unknown"
        }
        let masteringData = extensions[
            kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String
        ] as? Data
        let contentLightData = extensions[
            kCMFormatDescriptionExtension_ContentLightLevelInfo as String
        ] as? Data
        let ambientPath = "\(root).color.ambient_viewing_environment"
        let ambientViewingEnvironment = try
            AVCanonicalAmbientViewingEnvironmentCodecV4.decodeExtensionValue(
                extensions[
                    kCMFormatDescriptionExtension_AmbientViewingEnvironment
                        as String
                ],
                path: ambientPath
            )
        let mastering: CanonicalMasteringDisplayV4?
        if let masteringData {
            mastering = try decodeMasteringDisplay(masteringData, root: root)
        } else {
            mastering = nil
        }
        let contentLight: CanonicalContentLightLevelV4?
        if let contentLightData {
            contentLight = try decodeContentLight(contentLightData, root: root)
        } else {
            contentLight = nil
        }
        return CanonicalColorStateV4(
            primaries: colorString(
                kCMFormatDescriptionExtension_ColorPrimaries,
                name: "primaries"
            ),
            transferFunction: colorString(
                kCMFormatDescriptionExtension_TransferFunction,
                name: "transfer_function"
            ),
            matrix: colorString(
                kCMFormatDescriptionExtension_YCbCrMatrix,
                name: "matrix"
            ),
            masteringDisplay: mastering,
            contentLightLevel: contentLight,
            ambientViewingEnvironment: ambientViewingEnvironment,
            dynamicHDRMetadata: []
        )
    }

    func decodeMasteringDisplay(
        _ data: Data,
        root: String
    ) throws -> CanonicalMasteringDisplayV4 {
        guard data.count == 24 else {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: "\(root).mastering_display",
                reason: "expected 24 bytes, observed \(data.count)"
            )
        }
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> UInt16 {
            (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        }
        func u32(_ offset: Int) -> UInt32 {
            (UInt32(bytes[offset]) << 24)
                | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8)
                | UInt32(bytes[offset + 3])
        }
        return CanonicalMasteringDisplayV4(
            displayPrimariesX: try stride(from: 0, through: 8, by: 4).map {
                try ExactRationalV4(Int64(u16($0)), 50_000)
            },
            displayPrimariesY: try stride(from: 2, through: 10, by: 4).map {
                try ExactRationalV4(Int64(u16($0)), 50_000)
            },
            whitePointX: try ExactRationalV4(Int64(u16(12)), 50_000),
            whitePointY: try ExactRationalV4(Int64(u16(14)), 50_000),
            minimumLuminance: try ExactRationalV4(Int64(u32(20)), 10_000),
            maximumLuminance: try ExactRationalV4(Int64(u32(16)), 10_000)
        )
    }

    func decodeContentLight(
        _ data: Data,
        root: String
    ) throws -> CanonicalContentLightLevelV4 {
        guard data.count == 4 else {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: "\(root).content_light",
                reason: "expected 4 bytes, observed \(data.count)"
            )
        }
        let bytes = [UInt8](data)
        return CanonicalContentLightLevelV4(
            maximumContentLightLevel:
                UInt32((UInt16(bytes[0]) << 8) | UInt16(bytes[1])),
            maximumFrameAverageLightLevel:
                UInt32((UInt16(bytes[2]) << 8) | UInt16(bytes[3]))
        )
    }

    func scanState(
        _ extensions: NSDictionary,
        root: String,
        observations: inout [CanonicalMediaObservationV4]
    ) -> CanonicalScanStateV4 {
        do {
            return try AVCanonicalScanDescriptionV4(
                extensions: extensions
            ).state
        } catch AVCanonicalScanDescriptionV4Error.invalidFieldCount(
            let declaredCount
        ) {
            observations.append(
                observation(
                    severity: .error,
                    code: .unknownValue,
                    path: "\(root).field_count",
                    value: declaredCount.map(String.init) ?? "absent"
                )
            )
            return CanonicalScanStateV4(
                fieldCount: 1,
                dominance: .none,
                cadence: .unknown
            )
        } catch AVCanonicalScanDescriptionV4Error
            .contradictoryProgressiveFieldDetail(let detail) {
            observations.append(
                observation(
                    severity: .error,
                    code: .contradictory,
                    path: "\(root).field_dominance",
                    value: detail
                )
            )
            return CanonicalScanStateV4(
                fieldCount: 1,
                dominance: .unknown,
                cadence: .unknown
            )
        } catch AVCanonicalScanDescriptionV4Error.unsupportedFieldDetail(
            let detail
        ) {
            observations.append(
                observation(
                    severity: .unsupported,
                    code: .unknownValue,
                    path: "\(root).field_dominance",
                    value: detail ?? "absent"
                )
            )
            return CanonicalScanStateV4(
                fieldCount: 2,
                dominance: .unknown,
                cadence: .unknown
            )
        } catch {
            observations.append(
                observation(
                    severity: .error,
                    code: .malformed,
                    path: "\(root).scan",
                    value: String(describing: error)
                )
            )
            return CanonicalScanStateV4(
                fieldCount: 1,
                dominance: .unknown,
                cadence: .unknown
            )
        }
    }

    func canonicalEdits(
        _ segments: [AVAssetTrackSegment],
        root: String,
        observations: inout [CanonicalMediaObservationV4]
    ) throws -> [CanonicalMediaEditV4] {
        var edits: [CanonicalMediaEditV4] = []
        for (index, segment) in segments.enumerated() {
            let mapping = segment.timeMapping
            if segment.isEmpty {
                observations.append(
                    observation(
                        severity: .warning,
                        code: .unsupportedValue,
                        path: "\(root).edits[\(index)]",
                        value: "empty edit omitted from canonical edit rows; exact mapping fingerprinted in segment-mapping metadata and route topology is admitted separately"
                    )
                )
                continue
            }
            do {
                let sourceDuration = try ASHExactCMTimeV4.convert(
                    mapping.source.duration,
                    path: "\(root).edits[\(index)].source_duration"
                )
                let targetDuration = try ASHExactCMTimeV4.convert(
                    mapping.target.duration,
                    path: "\(root).edits[\(index)].target_duration"
                )
                guard !sourceDuration.isZero, !targetDuration.isZero else {
                    observations.append(
                        observation(
                            severity: .unsupported,
                            code: .unsupportedValue,
                            path: "\(root).edits[\(index)]",
                            value: "zero-rate or zero-duration edit fingerprinted"
                        )
                    )
                    continue
                }
                edits.append(
                    CanonicalMediaEditV4(
                        ordinal: UInt32(index),
                        sourceStart: try ASHExactCMTimeV4.convert(
                            mapping.source.start,
                            path: "\(root).edits[\(index)].source_start"
                        ),
                        sourceDuration: sourceDuration,
                        timelineStart: try ASHExactCMTimeV4.convert(
                            mapping.target.start,
                            path: "\(root).edits[\(index)].timeline_start"
                        ),
                        rate: try sourceDuration.divided(by: targetDuration)
                    )
                )
            } catch {
                observations.append(
                    observation(
                        severity: .unsupported,
                        code: .unsupportedValue,
                        path: "\(root).edits[\(index)]",
                        value: "unrepresentable exact timing: \(error)"
                    )
                )
            }
        }
        return edits
    }

    func canonicalSegmentMetadata(
        _ segments: [AVAssetTrackSegment],
        root: String
    ) throws -> [CanonicalMetadataValueV4] {
        try segments.enumerated().map { index, segment in
            let mapping = segment.timeMapping
            let envelope: [String: Any] = [
                "is_empty": NSNumber(value: segment.isEmpty),
                "source": [
                    "start": rawTimeProperty(mapping.source.start),
                    "duration": rawTimeProperty(mapping.source.duration)
                ],
                "target": [
                    "start": rawTimeProperty(mapping.target.start),
                    "duration": rawTimeProperty(mapping.target.duration)
                ]
            ]
            let data = try ASHCanonicalPropertyListV4.data(
                envelope,
                path: "\(root).segments[\(index)]"
            )
            return CanonicalMetadataValueV4(
                key: String(format: "segment-mapping-%06d", index),
                dataType: "application/vnd.apple.track-segment-mapping.v4",
                locale: nil,
                valueSHA256: ASHSHA256V4(rawData: data)
            )
        }
    }

    func rawTimeProperty(_ time: CMTime) -> [String: Any] {
        [
            "value": NSNumber(value: time.value),
            "timescale": NSNumber(value: time.timescale),
            "flags": NSNumber(value: time.flags.rawValue),
            "epoch": NSNumber(value: time.epoch)
        ]
    }

    func formatDescriptionMetadata(
        _ descriptions: [CMFormatDescription],
        root: String,
        observations: inout [CanonicalMediaObservationV4]
    ) throws -> [CanonicalMetadataValueV4] {
        try descriptions.enumerated().map { index, description in
            let extensions = (
                CMFormatDescriptionGetExtensions(description) as NSDictionary?
            ) ?? [:]
            let mediaType = CMFormatDescriptionGetMediaType(description)
            let mediaSubtype = CMFormatDescriptionGetMediaSubType(description)
            var envelope: [String: Any] = [
                "schema": "ash.cm-format-description.v4.1",
                "source_ordinal": NSNumber(value: index),
                "media_type": NSNumber(
                    value: mediaType
                ),
                "media_subtype": NSNumber(
                    value: mediaSubtype
                ),
                "extensions": extensions
            ]
            if mediaType == kCMMediaType_Video {
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                envelope["video_dimensions"] = [
                    "width": NSNumber(value: dimensions.width),
                    "height": NSNumber(value: dimensions.height)
                ]
                if mediaSubtype == kCMVideoCodecType_H264 {
                    let sets = h264ParameterSets(description)
                    envelope["nal_unit_header_length"] = NSNumber(
                        value: sets.headerLength
                    )
                    envelope["parameter_sets"] = sets.data
                    if sets.data.isEmpty {
                        observations.append(
                            observation(
                                severity: .error,
                                code: .missingRequiredValue,
                                path: "\(root).format_descriptions[\(index)].parameter_sets",
                                value: "H.264 format description has no readable parameter sets"
                            )
                        )
                    }
                } else if [
                    kCMVideoCodecType_HEVC,
                    kCMVideoCodecType_HEVCWithAlpha,
                    kCMVideoCodecType_DolbyVisionHEVC
                ].contains(mediaSubtype) {
                    let sets = hevcParameterSets(description)
                    envelope["nal_unit_header_length"] = NSNumber(
                        value: sets.headerLength
                    )
                    envelope["parameter_sets"] = sets.data
                    if sets.data.isEmpty {
                        observations.append(
                            observation(
                                severity: .error,
                                code: .missingRequiredValue,
                                path: "\(root).format_descriptions[\(index)].parameter_sets",
                                value: "HEVC format description has no readable parameter sets"
                            )
                        )
                    }
                }
            } else if mediaType == kCMMediaType_Audio {
                guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                    description
                )?.pointee else {
                    observations.append(
                        observation(
                            severity: .error,
                            code: .missingRequiredValue,
                            path: "\(root).format_descriptions[\(index)].audio_asbd",
                            value: "absent"
                        )
                    )
                    return CanonicalMetadataValueV4(
                        key: String(format: "format-description-%06d", index),
                        dataType: "application/vnd.apple.cm-format-description.v4",
                        locale: nil,
                        valueSHA256: ASHSHA256V4(rawData: try ASHCanonicalPropertyListV4.data(
                            envelope,
                            path: "\(root).format_descriptions[\(index)]"
                        ))
                    )
                }
                envelope["audio_asbd"] = [
                    "sample_rate_binary64": String(
                        format: "%016llx",
                        asbd.mSampleRate.bitPattern
                    ),
                    "format_id": NSNumber(value: asbd.mFormatID),
                    "format_flags": NSNumber(value: asbd.mFormatFlags),
                    "bytes_per_packet": NSNumber(value: asbd.mBytesPerPacket),
                    "frames_per_packet": NSNumber(value: asbd.mFramesPerPacket),
                    "bytes_per_frame": NSNumber(value: asbd.mBytesPerFrame),
                    "channels_per_frame": NSNumber(value: asbd.mChannelsPerFrame),
                    "bits_per_channel": NSNumber(value: asbd.mBitsPerChannel)
                ]
                var byteCount = 0
                if let pointer = CMAudioFormatDescriptionGetMagicCookie(
                    description,
                    sizeOut: &byteCount
                ) {
                    envelope["magic_cookie"] = Data(
                        bytes: pointer,
                        count: byteCount
                    )
                }
                byteCount = 0
                if let pointer = CMAudioFormatDescriptionGetChannelLayout(
                    description,
                    sizeOut: &byteCount
                ) {
                    envelope["channel_layout"] = Data(
                        bytes: pointer,
                        count: byteCount
                    )
                }
            }
            let data = try ASHCanonicalPropertyListV4.data(
                envelope,
                path: "\(root).format_descriptions[\(index)]"
            )
            return CanonicalMetadataValueV4(
                key: String(format: "format-description-%06d", index),
                dataType: "application/vnd.apple.cm-format-description.v4",
                locale: nil,
                valueSHA256: ASHSHA256V4(rawData: data)
            )
        }
    }

    func h264ParameterSets(
        _ description: CMFormatDescription
    ) -> (data: [Data], headerLength: Int32) {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        var headerLength: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description,
            parameterSetIndex: 0,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        ) == noErr else { return ([], 0) }
        var result: [Data] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { return ([], 0) }
            result.append(Data(bytes: pointer, count: size))
        }
        return (result, headerLength)
    }

    func hevcParameterSets(
        _ description: CMFormatDescription
    ) -> (data: [Data], headerLength: Int32) {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        var headerLength: Int32 = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            description,
            parameterSetIndex: 0,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        ) == noErr else { return ([], 0) }
        var result: [Data] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                description,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { return ([], 0) }
            result.append(Data(bytes: pointer, count: size))
        }
        return (result, headerLength)
    }

    func canonicalMetadata(
        _ items: [AVMetadataItem],
        keyPrefix: String,
        root: String,
        observations: inout [CanonicalMediaObservationV4]
    ) async throws -> [CanonicalMetadataValueV4] {
        var result: [CanonicalMetadataValueV4] = []
        result.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let itemPath = "\(root).\(keyPrefix)[\(index)]"
            let loadedValue = try await item.load(.value)
            let extraAttributes = try await item.load(.extraAttributes)
            if loadedValue == nil {
                observations.append(
                    observation(
                        severity: .warning,
                        code: .unknownValue,
                        path: "\(itemPath).value",
                        value: "nil"
                    )
                )
            }
            let identifier = item.identifier?.rawValue
                ?? "\(item.keySpace?.rawValue ?? "unknown")/unknown-key"
            let key: Any = item.key.map { $0 as Any } ?? NSNull()
            let envelope: [String: Any] = [
                "schema": "ash.avfoundation-metadata-item.v4.1",
                "source_ordinal": NSNumber(value: index),
                "identifier": item.identifier?.rawValue ?? NSNull(),
                "key_space": item.keySpace?.rawValue ?? NSNull(),
                "key": key,
                "common_key": item.commonKey?.rawValue ?? NSNull(),
                "data_type": item.dataType ?? NSNull(),
                "extended_language_tag": item.extendedLanguageTag ?? NSNull(),
                "locale": item.locale?.identifier ?? NSNull(),
                "time": rawTimeProperty(item.time),
                "duration": rawTimeProperty(item.duration),
                "extra_attributes": extraAttributes ?? [:],
                "value": loadedValue ?? NSNull()
            ]
            let identityData = try ASHCanonicalPropertyListV4.data(
                envelope,
                path: itemPath
            )
            result.append(
                CanonicalMetadataValueV4(
                    key: String(format: "%@-%06d-%@", keyPrefix, index, identifier),
                    dataType: item.dataType ?? "unknown",
                    locale: item.locale?.identifier ?? item.extendedLanguageTag,
                    valueSHA256: ASHSHA256V4(rawData: identityData)
                )
            )
        }
        return result
    }

    func scanDynamicHDR(
        asset: AVAsset,
        track: AVAssetTrack,
        root: String
    ) throws -> [CanonicalDynamicHDRMetadataV4] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: "\(root).dynamic_hdr_metadata",
                reason: "AVAssetReader rejected compressed track output"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: "\(root).dynamic_hdr_metadata",
                reason: reader.error.map(String.init(describing:)) ?? "reader failed"
            )
        }
        var result: [CanonicalDynamicHDRMetadataV4] = []
        var sampleOrdinal: UInt64 = 0
        while let aggregate = output.copyNextSampleBuffer() {
            let sampleCount = CMSampleBufferGetNumSamples(aggregate)
            guard sampleCount > 0 else { continue }
            if sampleCount == 1 {
                try appendDynamicIdentity(
                    sample: aggregate,
                    absoluteSampleOrdinal: sampleOrdinal,
                    to: &result
                )
                sampleOrdinal += 1
                continue
            }
            var subdivisionError: Error?
            let baseOrdinal = sampleOrdinal
            let status = CMSampleBufferCallBlockForEachSample(
                aggregate
            ) { sample, localIndex in
                do {
                    try appendDynamicIdentity(
                        sample: sample,
                        absoluteSampleOrdinal: baseOrdinal
                            + UInt64(localIndex),
                        to: &result
                    )
                    return noErr
                } catch {
                    subdivisionError = error
                    return -1
                }
            }
            if let subdivisionError { throw subdivisionError }
            guard status == noErr else {
                throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                    path: "\(root).dynamic_hdr_metadata",
                    reason: "sample subdivision failed with status \(status)"
                )
            }
            sampleOrdinal += UInt64(sampleCount)
        }
        guard reader.status == .completed else {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: "\(root).dynamic_hdr_metadata",
                reason: reader.error.map(String.init(describing:))
                    ?? "reader status \(reader.status.rawValue)"
            )
        }
        return result
    }

    struct RawCMTimeIdentity: Codable {
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

    struct DynamicHDRIdentity: Codable {
        let absoluteSampleOrdinal: UInt32
        let formatID: String
        let presentationTime: RawCMTimeIdentity
        let decodeTime: RawCMTimeIdentity
        let duration: RawCMTimeIdentity
        let hdr10PlusSHA256: ASHSHA256V4?
        let postDecodeProcessingSHA256: ASHSHA256V4?
    }

    func appendDynamicIdentity(
        sample: CMSampleBuffer,
        absoluteSampleOrdinal: UInt64,
        to result: inout [CanonicalDynamicHDRMetadataV4]
    ) throws {
        guard absoluteSampleOrdinal <= UInt64(UInt32.max) else {
            throw AVCanonicalMediaStateAdapterV4Error.avFoundationLoadFailed(
                path: "dynamic_hdr.sample_ordinal",
                reason: "sample ordinal exceeds UInt32 canonical domain"
            )
        }
        guard let metadata = try AVFoundationHDRMetadataAdapterV4
            .probeDynamicMetadata(from: sample) else { return }
        let hdr10PlusHash = metadata.hdr10Plus.map {
            ASHSHA256V4(rawData: $0.ituTT35Payload)
        }
        let postDecodeHash: ASHSHA256V4?
        if let postDecode = metadata.postDecodeProcessing {
            postDecodeHash = ASHSHA256V4(
                rawData: try ASHCanonicalPropertyListV4.data(
                    try postDecode.propertyListDictionary(),
                    path: "dynamic_hdr.post_decode_processing"
                )
            )
        } else {
            postDecodeHash = nil
        }
        let formatID: String
        switch (hdr10PlusHash, postDecodeHash) {
        case (.some, .some):
            formatID = "hdr10-plus-and-post-decode-processing"
        case (.some, .none):
            formatID = "hdr10-plus"
        case (.none, .some):
            formatID = "post-decode-processing"
        case (.none, .none):
            return
        }
        let ordinal = UInt32(absoluteSampleOrdinal)
        let identity = DynamicHDRIdentity(
            absoluteSampleOrdinal: ordinal,
            formatID: formatID,
            presentationTime: RawCMTimeIdentity(
                CMSampleBufferGetPresentationTimeStamp(sample)
            ),
            decodeTime: RawCMTimeIdentity(
                CMSampleBufferGetDecodeTimeStamp(sample)
            ),
            duration: RawCMTimeIdentity(CMSampleBufferGetDuration(sample)),
            hdr10PlusSHA256: hdr10PlusHash,
            postDecodeProcessingSHA256: postDecodeHash
        )
        result.append(CanonicalDynamicHDRMetadataV4(
            ordinal: ordinal,
            formatID: formatID,
            payloadSHA256: try ASHCanonicalJSONV4.hash(
                identity,
                domain: "ash-dynamic-hdr-sample-v4"
            )
        ))
    }

    func probeAssetMetadataTracks(
        _ asset: AVAsset,
        startingOrdinal: UInt32
    ) async -> VirtualTrackProbeResult {
        var tracks: [CanonicalMediaTrackV4] = []
        var observations: [CanonicalMediaObservationV4] = []
        do {
            let duration = try await asset.load(.duration)
            let durationRational = try ASHExactCMTimeV4.convert(
                duration,
                path: "asset.duration"
            )
            let timebase = try ExactRationalV4(1, Int64(duration.timescale))
            let assetMetadata = try await asset.load(.metadata)
            if !assetMetadata.isEmpty {
                let metadata = try await canonicalMetadata(
                    assetMetadata,
                    keyPrefix: "asset-metadata",
                    root: "asset",
                    observations: &observations
                )
                tracks.append(
                    CanonicalMediaTrackV4(
                        identity: CanonicalTrackIdentityV4(
                            ordinal: startingOrdinal,
                            persistentID: "virtual-asset-metadata"
                        ),
                        enabled: true,
                        kind: .auxiliaryMetadata,
                        languageTag: nil,
                        roleIDs: ["asset-level"],
                        codecID: "avfoundation-metadata",
                        timebase: timebase,
                        duration: durationRational,
                        edits: [],
                        metadata: metadata.sorted { $0.key < $1.key },
                        video: nil
                    )
                )
            }

            let locales = try await asset.load(.availableChapterLocales)
                .sorted { $0.identifier < $1.identifier }
            for (localeIndex, locale) in locales.enumerated() {
                let groups = try await asset.loadChapterMetadataGroups(
                    withTitleLocale: locale
                )
                var metadata: [CanonicalMetadataValueV4] = []
                for (groupIndex, group) in groups.enumerated() {
                    let groupRoot = "asset.chapters[\(localeIndex)][\(groupIndex)]"
                    let items = try await canonicalMetadata(
                        group.items,
                        keyPrefix: "chapter-item-\(groupIndex)",
                        root: groupRoot,
                        observations: &observations
                    )
                    let timing = try ASHCanonicalJSONV4.encode([
                        "start": try ASHExactCMTimeV4.convert(
                            group.timeRange.start,
                            path: "\(groupRoot).start"
                        ).description,
                        "duration": try ASHExactCMTimeV4.convert(
                            group.timeRange.duration,
                            path: "\(groupRoot).duration"
                        ).description
                    ])
                    metadata.append(
                        CanonicalMetadataValueV4(
                            key: String(
                                format: "chapter-group-%06d-timing",
                                groupIndex
                            ),
                            dataType: "application/vnd.ash.chapter-timing.v4",
                            locale: locale.identifier,
                            valueSHA256: ASHSHA256V4(rawData: timing)
                        )
                    )
                    metadata.append(contentsOf: items)
                }
                let ordinal = startingOrdinal
                    + UInt32(tracks.count)
                tracks.append(
                    CanonicalMediaTrackV4(
                        identity: CanonicalTrackIdentityV4(
                            ordinal: ordinal,
                            persistentID: "virtual-chapters-\(localeIndex)"
                        ),
                        enabled: true,
                        kind: .chapter,
                        languageTag: locale.identifier,
                        roleIDs: ["chapter"],
                        codecID: "avfoundation-chapter-metadata",
                        timebase: timebase,
                        duration: durationRational,
                        edits: [],
                        metadata: metadata.sorted { $0.key < $1.key },
                        video: nil
                    )
                )
            }
        } catch {
            observations.append(
                observation(
                    severity: .error,
                    code: .malformed,
                    path: "asset.metadata",
                    value: String(describing: error)
                )
            )
        }
        return VirtualTrackProbeResult(
            tracks: tracks,
            observations: observations.sorted()
        )
    }

    func classify(
        mediaType: AVMediaType,
        metadata: [AVMetadataItem],
        isChapter: Bool
    ) -> CanonicalMediaTrackKindV4 {
        let hasChapterIdentity = metadata.contains {
            $0.identifier?.rawValue.lowercased().contains("chapter") == true
        }
        switch mediaType {
        case .video: return .video
        case .audio: return .audio
        case .subtitle: return .subtitle
        case .closedCaption: return .caption
        case .text: return isChapter || hasChapterIdentity ? .chapter : .subtitle
        case .timecode: return .timecode
        case .metadata:
            return isChapter || hasChapterIdentity ? .chapter : .timedMetadata
        case .muxed, .haptic, .depthData, .auxiliaryPicture:
            return .auxiliaryMetadata
        default: return .unknown
        }
    }

    func exactInteger(_ number: NSNumber, path: String) throws -> Int64 {
        let type = String(cString: number.objCType)
        guard !["f", "d"].contains(type),
              let value = Int64(number.stringValue) else {
            let rational = try rational(number: number, path: path)
            guard let integer = rational.integerValue else {
                throw AVCanonicalMediaStateAdapterV4Error
                    .geometryOutsideExactRationalDomain(path: path)
            }
            return integer
        }
        return value
    }

    func rational(number: NSNumber, path: String) throws -> ExactRationalV4 {
        switch String(cString: number.objCType) {
        case "f":
            return try ASHExactBinaryRationalV4.convert(
                Double(number.floatValue),
                path: path
            )
        case "d":
            return try ASHExactBinaryRationalV4.convert(
                number.doubleValue,
                path: path
            )
        default:
            guard let value = Int64(number.stringValue) else {
                throw AVCanonicalMediaStateAdapterV4Error
                    .geometryOutsideExactRationalDomain(path: path)
            }
            return try ExactRationalV4(value)
        }
    }

    func hevcSemantics(_ extensions: NSDictionary) -> CodecSamplingSemantics? {
        guard let atoms = extensions["SampleDescriptionExtensionAtoms"]
                as? NSDictionary,
              let configuration = atoms["hvcC"] as? Data,
              configuration.count > 18 else {
            return nil
        }
        let bytes = [UInt8](configuration)
        let chroma = bytes[16] & 0x03
        let subsampling: CanonicalChromaSubsamplingV4 = switch chroma {
        case 0: .monochrome
        case 1: .yuv420
        case 2: .yuv422
        default: .yuv444
        }
        return CodecSamplingSemantics(
            bitDepth: 8 + (bytes[17] & 0x07),
            subsampling: subsampling
        )
    }

    func h264Semantics(
        _ description: CMFormatDescription
    ) -> CodecSamplingSemantics? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        var headerLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description,
            parameterSetIndex: 0,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard status == noErr, let pointer, size > 1 else { return nil }
        let nal = Array(UnsafeBufferPointer(start: pointer, count: size))
        let rbsp = removeEmulationPrevention(Array(nal.dropFirst()))
        guard rbsp.count >= 3 else { return nil }
        let profile = rbsp[0]
        var reader = BitReader(bytes: Array(rbsp.dropFirst(3)))
        guard reader.unsignedExpGolomb() != nil else { return nil }
        let highProfiles: Set<UInt8> = [
            44, 83, 86, 100, 110, 118, 122, 128, 134, 135, 138, 139, 244
        ]
        guard highProfiles.contains(profile) else {
            return CodecSamplingSemantics(bitDepth: 8, subsampling: .yuv420)
        }
        guard let chroma = reader.unsignedExpGolomb() else { return nil }
        if chroma == 3, reader.bit() == nil { return nil }
        guard let lumaMinusEight = reader.unsignedExpGolomb(),
              reader.unsignedExpGolomb() != nil,
              lumaMinusEight <= 8 else { return nil }
        let subsampling: CanonicalChromaSubsamplingV4 = switch chroma {
        case 0: .monochrome
        case 1: .yuv420
        case 2: .yuv422
        case 3: .yuv444
        default: .unknown
        }
        return CodecSamplingSemantics(
            bitDepth: UInt8(8 + lumaMinusEight),
            subsampling: subsampling
        )
    }

    struct BitReader {
        let bytes: [UInt8]
        var bitIndex = 0

        mutating func bit() -> UInt8? {
            guard bitIndex < bytes.count * 8 else { return nil }
            let value = (bytes[bitIndex / 8] >> (7 - bitIndex % 8)) & 1
            bitIndex += 1
            return value
        }

        mutating func unsignedExpGolomb() -> UInt64? {
            var leadingZeros = 0
            while let next = bit(), next == 0 {
                leadingZeros += 1
                guard leadingZeros < 63 else { return nil }
            }
            var suffix: UInt64 = 0
            for _ in 0..<leadingZeros {
                guard let next = bit() else { return nil }
                suffix = (suffix << 1) | UInt64(next)
            }
            return ((UInt64(1) << UInt64(leadingZeros)) - 1) + suffix
        }
    }

    func removeEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var zeroCount = 0
        for byte in bytes {
            if zeroCount >= 2, byte == 0x03 {
                zeroCount = 0
                continue
            }
            result.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        return result
    }

    func fourCC(_ value: FourCharCode) -> String {
        String(format: "fourcc-%08x", value)
    }

    func bigEndianASCII(_ value: String) -> UInt32 {
        value.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    func observation(
        severity: CanonicalMediaObservationSeverityV4,
        code: CanonicalMediaObservationCodeV4,
        path: String,
        value: String
    ) -> CanonicalMediaObservationV4 {
        CanonicalMediaObservationV4(
            severity: severity,
            code: code,
            path: path,
            observedValue: value
        )
    }
}
