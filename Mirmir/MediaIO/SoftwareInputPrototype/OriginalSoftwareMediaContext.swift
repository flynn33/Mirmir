import AVFoundation
import Foundation
import ObjectiveC

struct OriginalSoftwareDecodeParameter: Codable, Equatable, Sendable {
    let key: String
    let value: String
}

struct OriginalSoftwareWorkingVideoPolicy: Codable, Equatable, Sendable {
    let sourceOrdinal: Int32
    let sourceVideoSHA256: ASHSHA256V4
    let destinationFormatID: String
    let destinationRaster: CanonicalRasterV4
    let destinationBitDepth: UInt8
    let destinationRange: CanonicalPixelRangeV4
    let destinationChroma: CanonicalChromaSubsamplingV4
    let destinationSiting: CanonicalChromaSitingV4
    let destinationColor: CanonicalColorStateV4
    let converterID: String
    let converterVersion: String
    let parameters: [OriginalSoftwareDecodeParameter]

    static func qualifiesUnspecified8BitRange(stream: OriginalStream, timeline: TimingSummary,
                                              video: CanonicalVideoStateV4) -> Bool {
        guard stream.colorRange == 0, timeline.frameDepth == 8, video.pixel.bitDepth == 8,
              !timeline.hasHDRSideData else { return false }
        if stream.codecName == "wmv2" { return video.pixel.range == .video }
        return stream.codecName == "mpeg4" && timeline.legacyFullRange != nil
            && timeline.legacyFullRange == (video.pixel.range == .full)
    }

    static func destinationDepth(for video: CanonicalVideoStateV4) -> UInt8 { video.pixel.bitDepth == 8 ? 8 : 10 }
    static func destinationFormat(for video: CanonicalVideoStateV4) -> String {
        if destinationDepth(for: video) == 10 { return video.pixel.range == .full ? "xf20" : "x420" }
        return video.pixel.range == .full ? "420f" : "420v"
    }

    static func destinationSiting(for video: CanonicalVideoStateV4) throws -> CanonicalChromaSitingV4 {
        switch video.pixel.chromaSubsampling {
        case .yuv420:
            return video.pixel.chromaSiting
        case .yuv422:
            guard video.pixel.chromaSiting == .left || video.pixel.chromaSiting == .center else {
                throw ProbeFailure("unqualified original 422 horizontal phase")
            }
            // Vertical pairing changes only the vertical sample position.
            return video.pixel.chromaSiting
        case .yuv444, .rgb, .monochrome:
            return .center
        case .unknown:
            throw ProbeFailure("unknown original sampling phase")
        }
    }

    static func parameters(for video: CanonicalVideoStateV4,
        qualifiesUnspecifiedRange: Bool) -> [OriginalSoftwareDecodeParameter] {
        let rgb = video.pixel.chromaSubsampling == .rgb
        let destinationColor = destinationColor(for: video)
        return [
            .init(key: "chroma", value: rgb
                ? "encoded RGB 2x2 box mean; Kr=2126/10000 Kg=7152/10000 Kb=722/10000; Cb=128+(B-Y)/(2*(1-Kb)); Cr=128+(R-Y)/(2*(1-Kr)); exact rational nearest ties-to-even; clip0..255"
                : "420 identity; 422 vertical box; 444 2x2 box; integer nearest ties upward; odd edge uses all available source samples; no missing sample invented"),
            .init(key: "delivery", value: rgb ? "16-byte BE CV planar header plus exact rational RGB-derived NV12 planes; validated direct CVPixelBuffer copy; no native YUYV decoder" : "16-byte BE CV planar header plus exact NV12/P010 plane bytes; encoded reader followed by validated direct CVPixelBuffer copy; native raw decoder bypassed"),
            .init(key: "luma", value: rgb
                ? "full RGB8 encoded samples -> exact rational709 Y; no primaries or transfer transform"
                : "original eight-bit bytes unchanged"),
            .init(key: "matrix", value: destinationColor.matrix),
            .init(key: "originalMatrix", value: video.color.matrix),
            .init(key: "precision", value: "eight-bit retained; deeper input ->10bit; video range exact power-of-two code precision mapping; full range exact max-code rational mapping; nearest ties upward and representable clipping; no primary/transfer transform"),
            .init(key: "primaries", value: destinationColor.primaries),
            .init(key: "range", value: video.pixel.range.rawValue),
            .init(key: "sourceRangeInterpretation", value: qualifiesUnspecifiedRange
                ? "original frame range remains unspecified; separate qualified WMV2 or original MPEG4-VOL eight-bit working-range interpretation"
                : "original decoded explicit range must match selected working range"),
            .init(key: "transfer", value: destinationColor.transferFunction)
        ]
    }

    static func destinationColor(for video: CanonicalVideoStateV4) -> CanonicalColorStateV4 {
        guard video.pixel.chromaSubsampling == .rgb else { return video.color }
        return CanonicalColorStateV4(primaries: video.color.primaries,
            transferFunction: video.color.transferFunction, matrix: "ITU_R_709_2",
            masteringDisplay: video.color.masteringDisplay,
            contentLightLevel: video.color.contentLightLevel,
            ambientViewingEnvironment: video.color.ambientViewingEnvironment,
            dynamicHDRMetadata: video.color.dynamicHDRMetadata)
    }
}

struct OriginalSoftwareWorkingDecodePolicy: Codable, Equatable, Sendable {
    let carrierID: String
    let carrierVersion: String
    let parameters: [OriginalSoftwareDecodeParameter]
    let tracks: [OriginalSoftwareWorkingVideoPolicy]

    static func parameters(workingOffset: ExactRationalV4) -> [OriginalSoftwareDecodeParameter] {
        [
            .init(key: "audio", value: "AAC LC and PCM16 original authenticated packets are retained where qualified; AAC original leading skip is an exact edit; incompatible audio uses same-rate/layout S32 with manual skip/padding excluded; every raw clock retained"),
            .init(key: "audioLayout", value: "one original unmixed channel delivered as center mono even when original channel order/mask is unspecified; explicit FL/FR stereo otherwise; raw source layout retained"),
            .init(key: "decoder", value: "FFmpeg8.1.2 LGPL universal baseline; one thread; BITEXACT COPY_OPAQUE SKIP_MANUAL; software only; no cross-architecture PCM parity claim"),
            .init(key: "timeline", value: "original container global origin retained; one exact earliest selected presentation becomes common working origin; source video PTS differences/duration preserved; shared carrier offset=\(workingOffset); no nominal-clock rewrite")
        ]
    }

    var canonicalSHA256: ASHSHA256V4 {
        get throws {
            try ASHCanonicalJSONV4.hash(
                self, domain: "mirmir-original-source-working-decode-policy-v1"
            )
        }
    }
}

/// Derived execution identity beside the original media projection. The source
/// bookmark may be rebound by the existing request API; media facts are exact.
struct OriginalSoftwareWorkingDecodeEnvelope: Codable, Equatable, Sendable {
    static let schemaID = "mirmir.original-software-working-decode-envelope.v2"
    let schemaID: String
    let sourceProjectionInput: CanonicalInputIdentityV4
    let originalProjectionSHA256: ASHSHA256V4
    let originalGraphSHA256: ASHSHA256V4
    let originalFactsSHA256: ASHSHA256V4
    let originalGlobalOrigin: ExactRationalV4
    let sharedWorkingOffset: ExactRationalV4
    let decodePolicy: OriginalSoftwareWorkingDecodePolicy
    let implementationIdentity: SoftwareInputImplementationIdentity

    var canonicalSHA256: ASHSHA256V4 {
        get throws { try ASHCanonicalJSONV4.hash(self,
            domain: "mirmir-original-software-working-decode-envelope-v2") }
    }

    func verify(originalCanonicalMedia: CanonicalMediaStateV4,
        originalGraph: MediaTrackGraphV4) throws {
        // Only the already authorized bookmark-reference rebinding is normalized
        // for comparison. The caller's original state is never rewritten.
        try implementationIdentity.verifyCurrent()
        try originalCanonicalMedia.validate()
        try originalGraph.validate()
        let originalVideos = originalCanonicalMedia.tracks.filter { $0.kind == .video }
        let videoOrdinals = originalVideos.compactMap { Int32(exactly: $0.identity.ordinal) }
        let projection = try CanonicalMediaStateV4(input: sourceProjectionInput,
            tracks: originalCanonicalMedia.tracks, observations: originalCanonicalMedia.observations)
        guard schemaID == Self.schemaID,
              sourceProjectionInput.contentSHA256 == originalCanonicalMedia.input.contentSHA256,
              sourceProjectionInput.byteCount == originalCanonicalMedia.input.byteCount,
              sourceProjectionInput.fileName == originalCanonicalMedia.input.fileName,
              try projection.canonicalSHA256 == originalProjectionSHA256,
              try originalGraph.canonicalSHA256 == originalGraphSHA256,
              originalCanonicalMedia.tracks.flatMap(\.metadata).contains(where: {
                $0.key == "original-source-facts" && $0.valueSHA256 == originalFactsSHA256
              }),
              decodePolicy.carrierID == "mirmir-private-on-demand-working-mov",
              decodePolicy.carrierVersion == "4",
              decodePolicy.parameters == OriginalSoftwareWorkingDecodePolicy.parameters(workingOffset: sharedWorkingOffset),
              videoOrdinals.count == originalVideos.count,
              decodePolicy.tracks.map(\.sourceOrdinal) == videoOrdinals else {
            throw ProbeFailure("original software decode envelope identity differs")
        }
        for policy in decodePolicy.tracks {
            guard policy.sourceOrdinal >= 0,
                  let source = originalCanonicalMedia.tracks.first(where: { $0.identity.ordinal == UInt32(policy.sourceOrdinal) }),
                  let video = source.video,
                  policy.sourceVideoSHA256 == (try ASHCanonicalJSONV4.hash(video, domain: "mirmir-original-video-semantics-v1")),
                  policy.destinationRaster == video.encodedRaster,
                  policy.destinationFormatID == OriginalSoftwareWorkingVideoPolicy.destinationFormat(for: video),
                  policy.destinationBitDepth == OriginalSoftwareWorkingVideoPolicy.destinationDepth(for: video),
                  policy.destinationRange == video.pixel.range,
                  policy.destinationChroma == .yuv420,
                  policy.destinationSiting == (try OriginalSoftwareWorkingVideoPolicy.destinationSiting(for: video)),
                  policy.destinationColor == OriginalSoftwareWorkingVideoPolicy.destinationColor(for: video),
                  policy.converterVersion == "2",
                  policy.converterID == (video.pixel.chromaSubsampling == .rgb
                    ? "mirmir-rgb8-rational420-raw-biplanar-delivery"
                    : "mirmir-opaque-yuv-rational420-raw-biplanar-delivery") else {
                throw ProbeFailure("working decode envelope video contract differs")
            }
            let qualified = policy.parameters.first(where: { $0.key == "sourceRangeInterpretation" })?.value
                == "original frame range remains unspecified; separate qualified WMV2 or original MPEG4-VOL eight-bit working-range interpretation"
            guard !qualified || video.pixel.bitDepth == 8
                    && (source.codecID.hasSuffix("-wmv2") || source.codecID.hasSuffix("-mpeg4")),
                  policy.parameters == OriginalSoftwareWorkingVideoPolicy.parameters(for: video,
                    qualifiesUnspecifiedRange: qualified) else {
                throw ProbeFailure("working decode envelope parameters differ")
            }
        }
    }
}

struct OriginalSoftwareTrackBinding: Codable, Equatable {
    let sourceOrdinal: Int32
    let sourceContainerID: Int32
    let canonicalTrackID: String
    let graphTrackID: MediaTrackStableIDV4
    let mediaType: Int32
    let sourceCodecID: Int32
    let sourceCodecPrivateSHA256: ASHSHA256V4
}

/// Private integration proof. The original source owns its canonical identity;
/// the asset receiving this context is only a working sample delivery surface.
final class OriginalSoftwareMediaContext: @unchecked Sendable {
    private static var associationKey: UInt8 = 0
    let originalProbe: OriginalProbe
    let sourceFacts: SourceFacts
    let sharedOrigin: SharedOrigin
    let timings: [TimingSummary]
    let typedProjection: TypedProjection
    let trackBindings: [OriginalSoftwareTrackBinding]
    let workingDecodePolicy: OriginalSoftwareWorkingDecodePolicy?
    let evidenceDirectory: URL

    private init(
        probe: OriginalProbe, source: SourceFacts, origin: SharedOrigin,
        timings: [TimingSummary], projection: TypedProjection,
        bindings: [OriginalSoftwareTrackBinding],
        workingDecodePolicy: OriginalSoftwareWorkingDecodePolicy?,
        evidenceDirectory: URL
    ) {
        originalProbe = probe
        sourceFacts = source
        sharedOrigin = origin
        self.timings = timings
        typedProjection = projection
        trackBindings = bindings
        self.workingDecodePolicy = workingDecodePolicy
        self.evidenceDirectory = evidenceDirectory
    }

    static func make(
        url: URL, cancellation: (any NativeMediaInputCancellationV4)? = nil,
        sourceIdentity: ASHStreamingFileIdentityV4? = nil
    ) async throws -> OriginalSoftwareMediaContext {
        let probe = try OriginalProbe(
            url: url, cancellation: cancellation, sourceIdentity: sourceIdentity
        )
        let source = try await probe.sourceFacts()
        guard let start = try source.start?.seconds else {
            throw ProbeFailure("missing original asset clock origin")
        }
        let origin = SharedOrigin(
            seconds: start,
            evidence: "one original container/libav global origin applied unchanged to every source clock; raw quantized/nominal clocks retained"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-original-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var timings: [TimingSummary] = []
        for stream in source.streams {
            try probe.checkCancellation()
            timings.append(try probe.timeline(
                stream, origin: origin, directory: directory
            ))
        }
        let placeholder = ASHSHA256V4(rawData: Data(
            "private source-context placeholder; adapter must bind actual bookmark document".utf8
        ))
        let projection = try await OriginalFactsTranslator.translate(
            probe: probe, source: source, origin: origin,
            timings: timings, bookmarkHash: placeholder
        )
        try probe.checkCancellation()
        var error = MIBError()
        try check(mib_source_authenticate(probe.source, &error), error)
        try probe.file.verifyUnchanged(url: url)
        guard projection.report.reasons.isEmpty,
              let state = projection.state, let graph = projection.graph,
              projection.videoInfo != nil else {
            throw ProbeFailure("original-source projection: "
                + projection.report.reasons.joined(separator: "; "))
        }
        let bindings = try source.streams.map { stream in
            guard let track = state.tracks.first(where: {
                $0.identity.ordinal == UInt32(stream.ordinal)
            }), let node = graph.tracks.first(where: {
                $0.identity.ordinal == UInt32(stream.ordinal)
            }) else { throw ProbeFailure("original stream binding missing") }
            return OriginalSoftwareTrackBinding(
                sourceOrdinal: stream.ordinal,
                sourceContainerID: stream.libraryContainerID,
                canonicalTrackID: track.identity.persistentID,
                graphTrackID: node.identity.stableID,
                mediaType: stream.mediaType,
                sourceCodecID: stream.codecID,
                sourceCodecPrivateSHA256: ASHSHA256V4(rawData: stream.extradata)
            )
        }
        try ASHCanonicalJSONV4.encode(projection.report).write(
            to: directory.appendingPathComponent("projection.json")
        )
        return OriginalSoftwareMediaContext(
            probe: probe, source: source, origin: origin, timings: timings,
            projection: projection, bindings: bindings,
            workingDecodePolicy: nil, evidenceDirectory: directory
        )
    }

    func sourceVideoSHA256(ordinal: Int32) throws -> ASHSHA256V4 {
        guard ordinal >= 0 else { throw ProbeFailure("invalid source video ordinal") }
        guard let video = typedProjection.state?.tracks.first(where: {
            $0.identity.ordinal == UInt32(ordinal) && $0.kind == .video
        })?.video else { throw ProbeFailure("missing source video ordinal") }
        return try ASHCanonicalJSONV4.hash(
            video, domain: "mirmir-original-video-semantics-v1"
        )
    }

    func bindingWorkingDecodePolicy(
        _ policy: OriginalSoftwareWorkingDecodePolicy
    ) throws -> OriginalSoftwareMediaContext {
        guard workingDecodePolicy == nil,
              !policy.carrierID.isEmpty, !policy.carrierVersion.isEmpty,
              policy.parameters.map(\.key)
                == Array(Set(policy.parameters.map(\.key))).sorted(),
              policy.tracks.map(\.sourceOrdinal)
                == sourceFacts.streams.filter({ $0.mediaType == 0 }).map(\.ordinal)
        else { throw ProbeFailure("working decode policy inventory/identity") }
        for track in policy.tracks {
            guard track.sourceVideoSHA256
                    == (try sourceVideoSHA256(ordinal: track.sourceOrdinal)),
                  track.destinationRaster == typedProjection.state?.tracks.first(where: {
                      $0.identity.ordinal == UInt32(track.sourceOrdinal)
                  })?.video?.encodedRaster,
                  !track.destinationFormatID.isEmpty,
                  (1...16).contains(track.destinationBitDepth),
                  track.destinationRange != .unknown,
                  track.destinationChroma != .unknown,
                  track.destinationSiting != .unknown,
                  !track.converterID.isEmpty, !track.converterVersion.isEmpty,
                  track.parameters.map(\.key)
                    == Array(Set(track.parameters.map(\.key))).sorted()
            else { throw ProbeFailure("working decode policy source/conversion contract") }
        }
        for track in policy.tracks {
            guard let video = typedProjection.state?.tracks.first(where: {
                $0.identity.ordinal == UInt32(track.sourceOrdinal)
            })?.video else { throw ProbeFailure("missing original working color source") }
            let expectedColor = OriginalSoftwareWorkingVideoPolicy.destinationColor(for: video)
            guard track.destinationColor == expectedColor else {
                throw ProbeFailure("working color interpretation differs from source-bound conversion")
            }
        }
        let result = OriginalSoftwareMediaContext(
            probe: originalProbe, source: sourceFacts, origin: sharedOrigin,
            timings: timings, projection: typedProjection, bindings: trackBindings,
            workingDecodePolicy: policy, evidenceDirectory: evidenceDirectory
        )
        _ = try result.workingDecodeEnvelope()
        return result
    }

    func workingDecodeEnvelope() throws -> OriginalSoftwareWorkingDecodeEnvelope {
        guard let workingDecodePolicy, let state = typedProjection.state,
              let graph = typedProjection.graph else {
            throw ProbeFailure("working decode envelope requires original projection")
        }
        for policy in workingDecodePolicy.tracks {
            guard policy.sourceOrdinal >= 0, Int(policy.sourceOrdinal) < timings.count,
                  let stream = sourceFacts.streams.first(where: { $0.ordinal == policy.sourceOrdinal }),
                  let video = state.tracks.first(where: { $0.identity.ordinal == UInt32(policy.sourceOrdinal) })?.video,
                  policy.parameters == OriginalSoftwareWorkingVideoPolicy.parameters(for: video,
                    qualifiesUnspecifiedRange: OriginalSoftwareWorkingVideoPolicy.qualifiesUnspecified8BitRange(
                        stream: stream, timeline: timings[Int(policy.sourceOrdinal)], video: video)) else {
                throw ProbeFailure("working decode parameters differ from authenticated original facts")
            }
        }
        let envelope = OriginalSoftwareWorkingDecodeEnvelope(
            schemaID: OriginalSoftwareWorkingDecodeEnvelope.schemaID,
            sourceProjectionInput: state.input,
            originalProjectionSHA256: try state.canonicalSHA256,
            originalGraphSHA256: try graph.canonicalSHA256,
            originalFactsSHA256: typedProjection.report.originalFactsSHA256,
            originalGlobalOrigin: sharedOrigin.seconds,
            sharedWorkingOffset: try SoftwareVirtualCarrier.sharedWorkingOffset(self),
            decodePolicy: workingDecodePolicy,
            implementationIdentity: originalProbe.implementationIdentity
        )
        try envelope.verify(originalCanonicalMedia: state, originalGraph: graph)
        return envelope
    }

    func canonicalProbe(
        request: AVCanonicalMediaStateProbeRequestV4,
        fileIdentity: ASHStreamingFileIdentityV4
    ) throws -> AVCanonicalMediaStateProbeV4 {
        guard request.url.standardizedFileURL == originalProbe.url.standardizedFileURL,
              fileIdentity.contentSHA256 == sourceFacts.sourceHash,
              fileIdentity.byteCount == sourceFacts.sourceBytes,
              workingDecodePolicy != nil,
              let state = typedProjection.state else {
            throw ProbeFailure("original source identity/working policy changed")
        }
        _ = try workingDecodeEnvelope()
        try originalProbe.file.verifyUnchanged(url: request.url)
        let rebound = try CanonicalMediaStateV4(
            input: CanonicalInputIdentityV4(
                contentSHA256: sourceFacts.sourceHash, byteCount: sourceFacts.sourceBytes,
                fileName: sourceFacts.filename,
                bookmarkReference: request.bookmarkReference,
                bookmarkDocumentSHA256: request.bookmarkDocumentSHA256
            ), tracks: state.tracks, observations: state.observations
        )
        return AVCanonicalMediaStateProbeV4(state: rebound, admission: .admitted)
    }

    func associate(to asset: AVURLAsset) throws {
        guard workingDecodePolicy != nil else {
            throw ProbeFailure("working decode contract must precede association")
        }
        _ = try workingDecodeEnvelope()
        objc_setAssociatedObject(
            asset, &Self.associationKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func associated(with asset: AVAsset) -> OriginalSoftwareMediaContext? {
        objc_getAssociatedObject(asset, &associationKey)
            as? OriginalSoftwareMediaContext
    }
}
