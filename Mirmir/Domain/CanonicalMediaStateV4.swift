import Foundation

enum CanonicalMediaStateV4Error: Error, Equatable, Sendable {
    case unsupportedSchema(String)
    case invalidInputIdentity
    case invalidTrackOrdering
    case duplicateTrackIdentity(String)
    case invalidTrack(String)
    case invalidVideoGeometry(String)
    case invalidVideoSemantics(String)
    case invalidStableOrdering(String)
}

enum CanonicalMediaTrackKindV4: String, Codable, CaseIterable, Hashable,
    Sendable {
    case video
    case audio
    case subtitle
    case caption
    case chapter
    case timecode
    case timedMetadata = "timed_metadata"
    case auxiliaryMetadata = "auxiliary_metadata"
    case unknown
}

enum CanonicalPixelRangeV4: String, Codable, Hashable, Sendable {
    case video
    case full
    case unknown
}

enum CanonicalChromaSubsamplingV4: String, Codable, Hashable, Sendable {
    case yuv420 = "4:2:0"
    case yuv422 = "4:2:2"
    case yuv444 = "4:4:4"
    case rgb
    case monochrome
    case unknown
}

enum CanonicalChromaSitingV4: String, Codable, Hashable, Sendable {
    case left
    case center
    case topLeft = "top_left"
    case top
    case bottomLeft = "bottom_left"
    case bottom
    case notApplicable = "not_applicable"
    case unknown
}

enum CanonicalAlphaModelV4: String, Codable, Hashable, Sendable {
    case none
    case straight
    case premultiplied
    case unknown
}

enum CanonicalFieldDominanceV4: String, Codable, Hashable, Sendable {
    case none
    case topFieldFirst = "top_field_first"
    case bottomFieldFirst = "bottom_field_first"
    case unknown
}

enum CanonicalCadenceV4: String, Codable, Hashable, Sendable {
    case progressive
    case interlaced
    case telecine32 = "telecine_3_2"
    case mixed
    case unknown
}

enum CanonicalMediaObservationSeverityV4: String, Codable, Hashable,
    Sendable {
    case information
    case warning
    case error
    case unsupported
}

enum CanonicalMediaObservationCodeV4: String, Codable, Hashable, Sendable {
    case malformed
    case contradictory
    case unknownValue = "unknown_value"
    case unsupportedValue = "unsupported_value"
    case missingRequiredValue = "missing_required_value"
}

struct CanonicalRasterV4: Codable, Equatable, Hashable, Sendable {
    let width: Int64
    let height: Int64
}

struct CanonicalRationalPointV4: Codable, Equatable, Hashable, Sendable {
    let x: ExactRationalV4
    let y: ExactRationalV4
}

struct CanonicalRationalSizeV4: Codable, Equatable, Hashable, Sendable {
    let width: ExactRationalV4
    let height: ExactRationalV4
}

struct CanonicalRationalRectV4: Codable, Equatable, Hashable, Sendable {
    let origin: CanonicalRationalPointV4
    let size: CanonicalRationalSizeV4
}

struct CanonicalAffineTransformV4: Codable, Equatable, Hashable, Sendable {
    let a: ExactRationalV4
    let b: ExactRationalV4
    let c: ExactRationalV4
    let d: ExactRationalV4
    let tx: ExactRationalV4
    let ty: ExactRationalV4

    static let identity = CanonicalAffineTransformV4(
        a: .one,
        b: .zero,
        c: .zero,
        d: .one,
        tx: .zero,
        ty: .zero
    )
}

struct CanonicalInputIdentityV4: Codable, Equatable, Hashable, Sendable {
    let contentSHA256: ASHSHA256V4
    let byteCount: Int64
    let fileName: String
    /// Stable identifier for a separately encrypted bookmark document. Raw
    /// security-scoped bookmark bytes never enter a plan or diagnostic.
    let bookmarkReference: String
    let bookmarkDocumentSHA256: ASHSHA256V4
}

struct CanonicalTrackIdentityV4: Codable, Comparable, Equatable, Hashable,
    Sendable {
    let ordinal: UInt32
    let persistentID: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
        return lhs.persistentID < rhs.persistentID
    }
}

struct CanonicalMediaEditV4: Codable, Equatable, Hashable, Sendable {
    let ordinal: UInt32
    let sourceStart: ExactRationalV4
    let sourceDuration: ExactRationalV4
    let timelineStart: ExactRationalV4
    let rate: ExactRationalV4
}

struct CanonicalMetadataValueV4: Codable, Equatable, Hashable, Sendable {
    let key: String
    let dataType: String
    let locale: String?
    let valueSHA256: ASHSHA256V4
}

struct CanonicalDynamicHDRMetadataV4: Codable, Equatable, Hashable, Sendable {
    let ordinal: UInt32
    let formatID: String
    let payloadSHA256: ASHSHA256V4
}

struct CanonicalMasteringDisplayV4: Codable, Equatable, Hashable, Sendable {
    let displayPrimariesX: [ExactRationalV4]
    let displayPrimariesY: [ExactRationalV4]
    let whitePointX: ExactRationalV4
    let whitePointY: ExactRationalV4
    let minimumLuminance: ExactRationalV4
    let maximumLuminance: ExactRationalV4
}

struct CanonicalContentLightLevelV4: Codable, Equatable, Hashable, Sendable {
    let maximumContentLightLevel: UInt32
    let maximumFrameAverageLightLevel: UInt32
}

/// Typed semantic form of the ITU-T H.274 ambient-viewing-environment SEI
/// carried by an ITU-T H.265/HEVC bitstream.
/// Illuminance is expressed in lux and chromaticity in normalized x/y units;
/// exact rationals retain every bit of the eight-byte payload.
struct CanonicalAmbientViewingEnvironmentV4: Codable, Equatable, Hashable,
    Sendable {
    let ambientIlluminance: ExactRationalV4
    let ambientLightX: ExactRationalV4
    let ambientLightY: ExactRationalV4
}

struct CanonicalColorStateV4: Codable, Equatable, Hashable, Sendable {
    let primaries: String
    let transferFunction: String
    let matrix: String
    let masteringDisplay: CanonicalMasteringDisplayV4?
    let contentLightLevel: CanonicalContentLightLevelV4?
    let ambientViewingEnvironment: CanonicalAmbientViewingEnvironmentV4?
    let dynamicHDRMetadata: [CanonicalDynamicHDRMetadataV4]

    init(
        primaries: String,
        transferFunction: String,
        matrix: String,
        masteringDisplay: CanonicalMasteringDisplayV4?,
        contentLightLevel: CanonicalContentLightLevelV4?,
        ambientViewingEnvironment: CanonicalAmbientViewingEnvironmentV4? = nil,
        dynamicHDRMetadata: [CanonicalDynamicHDRMetadataV4]
    ) {
        self.primaries = primaries
        self.transferFunction = transferFunction
        self.matrix = matrix
        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel
        self.ambientViewingEnvironment = ambientViewingEnvironment
        self.dynamicHDRMetadata = dynamicHDRMetadata
    }
}

struct CanonicalFieldChromaSitingV4: Codable, Equatable, Hashable, Sendable {
    static let schemaID = "ash.field-chroma-siting.v4.1"
    let schemaID: String
    let top: CanonicalChromaSitingV4
    let bottom: CanonicalChromaSitingV4

    init(top: CanonicalChromaSitingV4, bottom: CanonicalChromaSitingV4) {
        self.schemaID = Self.schemaID
        self.top = top
        self.bottom = bottom
    }

    var isValid: Bool {
        let known: Set<CanonicalChromaSitingV4> = [.left, .center, .topLeft, .top, .bottomLeft, .bottom]
        return schemaID == Self.schemaID && known.contains(top) && known.contains(bottom) && top != bottom
    }
}

struct CanonicalPixelStateV4: Codable, Equatable, Hashable, Sendable {
    let formatID: String
    let bitDepth: UInt8
    let range: CanonicalPixelRangeV4
    let chromaSubsampling: CanonicalChromaSubsamplingV4
    let chromaSiting: CanonicalChromaSitingV4
    let alphaModel: CanonicalAlphaModelV4
    var fieldChromaSiting: CanonicalFieldChromaSitingV4? = nil
}

struct CanonicalScanStateV4: Codable, Equatable, Hashable, Sendable {
    let fieldCount: UInt8
    let dominance: CanonicalFieldDominanceV4
    let cadence: CanonicalCadenceV4
}

struct CanonicalVideoStateV4: Codable, Equatable, Hashable, Sendable {
    let encodedRaster: CanonicalRasterV4
    let presentationRaster: CanonicalRasterV4
    let preferredTransform: CanonicalAffineTransformV4
    let cleanAperture: CanonicalRationalRectV4?
    let pixelAspectRatio: ExactRationalV4
    let pixel: CanonicalPixelStateV4
    let color: CanonicalColorStateV4
    let scan: CanonicalScanStateV4
}

struct CanonicalMediaTrackV4: Codable, Equatable, Hashable, Sendable {
    let identity: CanonicalTrackIdentityV4
    let enabled: Bool
    let kind: CanonicalMediaTrackKindV4
    let languageTag: String?
    let roleIDs: [String]
    let codecID: String
    /// Seconds represented exactly as a reduced rational per media tick.
    let timebase: ExactRationalV4
    let duration: ExactRationalV4
    let edits: [CanonicalMediaEditV4]
    let metadata: [CanonicalMetadataValueV4]
    let video: CanonicalVideoStateV4?
}

struct CanonicalMediaObservationV4: Codable, Comparable, Equatable, Hashable,
    Sendable {
    let severity: CanonicalMediaObservationSeverityV4
    let code: CanonicalMediaObservationCodeV4
    let path: String
    let observedValue: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        if lhs.code.rawValue != rhs.code.rawValue {
            return lhs.code.rawValue < rhs.code.rawValue
        }
        if lhs.severity.rawValue != rhs.severity.rawValue {
            return lhs.severity.rawValue < rhs.severity.rawValue
        }
        return lhs.observedValue < rhs.observedValue
    }
}

/// Immutable, platform-independent result of probing one input asset. Platform
/// adapters may construct this value, but no AVFoundation or CoreMedia type is
/// allowed across this boundary.
struct CanonicalMediaStateV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaID = "ash.canonical-media-state.v4.1"
    static let fieldChromaSchemaID = "ash.canonical-media-state.v4.2"
    static let identityDomain = "ash-canonical-media-state-v4"

    let schemaID: String
    let input: CanonicalInputIdentityV4
    let tracks: [CanonicalMediaTrackV4]
    let observations: [CanonicalMediaObservationV4]

    init(
        input: CanonicalInputIdentityV4,
        tracks: [CanonicalMediaTrackV4],
        observations: [CanonicalMediaObservationV4]
    ) throws {
        self.schemaID = tracks.contains(where: { $0.video?.pixel.fieldChromaSiting != nil })
            ? Self.fieldChromaSchemaID : Self.currentSchemaID
        self.input = input
        self.tracks = tracks
        self.observations = observations
        try validate()
    }

    func validate() throws {
        let containsFieldPair = tracks.contains(where: { $0.video?.pixel.fieldChromaSiting != nil })
        guard schemaID == (containsFieldPair ? Self.fieldChromaSchemaID : Self.currentSchemaID) else {
            throw CanonicalMediaStateV4Error.unsupportedSchema(schemaID)
        }
        guard input.byteCount >= 0,
              Self.isStableIdentifier(input.bookmarkReference),
              !input.fileName.isEmpty,
              !input.fileName.contains("/"),
              !input.fileName.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw CanonicalMediaStateV4Error.invalidInputIdentity
        }
        guard tracks == tracks.sorted(by: { $0.identity < $1.identity }) else {
            throw CanonicalMediaStateV4Error.invalidTrackOrdering
        }
        var trackIDs = Set<String>()
        var ordinals = Set<UInt32>()
        for track in tracks {
            guard trackIDs.insert(track.identity.persistentID).inserted else {
                throw CanonicalMediaStateV4Error.duplicateTrackIdentity(
                    track.identity.persistentID
                )
            }
            guard ordinals.insert(track.identity.ordinal).inserted,
                  Self.isStableIdentifier(track.identity.persistentID),
                  Self.isStableIdentifier(track.codecID),
                  track.timebase.isPositive,
                  track.duration >= .zero,
                  track.roleIDs == Array(Set(track.roleIDs)).sorted(),
                  track.edits.map(\.ordinal) == track.edits.map(\.ordinal).sorted(),
                  Set(track.edits.map(\.ordinal)).count == track.edits.count,
                  track.metadata.map(\.key) == track.metadata.map(\.key).sorted(),
                  Set(track.metadata.map(\.key)).count == track.metadata.count,
                  track.edits.allSatisfy({
                      $0.sourceDuration >= .zero && $0.rate.isPositive
                  }) else {
                throw CanonicalMediaStateV4Error.invalidTrack(
                    track.identity.persistentID
                )
            }
            guard (track.kind == .video) == (track.video != nil) else {
                throw CanonicalMediaStateV4Error.invalidTrack(
                    track.identity.persistentID
                )
            }
            if let video = track.video {
                try validate(video, trackID: track.identity.persistentID)
            }
        }
        guard observations == observations.sorted() else {
            throw CanonicalMediaStateV4Error.invalidStableOrdering(
                "observations"
            )
        }
    }

    var canonicalSHA256: ASHSHA256V4 {
        get throws {
            try validate()
            return try ASHCanonicalJSONV4.hash(
                self,
                domain: Self.identityDomain
            )
        }
    }

    private func validate(
        _ video: CanonicalVideoStateV4,
        trackID: String
    ) throws {
        guard video.encodedRaster.width > 0,
              video.encodedRaster.height > 0,
              video.presentationRaster.width > 0,
              video.presentationRaster.height > 0,
              video.pixelAspectRatio.isPositive,
              video.cleanAperture.map({
                  $0.size.width.isPositive && $0.size.height.isPositive
              }) ?? true else {
            throw CanonicalMediaStateV4Error.invalidVideoGeometry(trackID)
        }
        guard (1...16).contains(video.pixel.bitDepth),
              Self.isStableIdentifier(video.pixel.formatID),
              Self.isStableIdentifier(video.color.primaries),
              Self.isStableIdentifier(video.color.transferFunction),
              Self.isStableIdentifier(video.color.matrix),
              video.color.dynamicHDRMetadata.map(\.ordinal)
                == video.color.dynamicHDRMetadata.map(\.ordinal).sorted(),
              Set(video.color.dynamicHDRMetadata.map(\.ordinal)).count
                == video.color.dynamicHDRMetadata.count else {
            throw CanonicalMediaStateV4Error.invalidVideoSemantics(trackID)
        }
        if let pair = video.pixel.fieldChromaSiting {
            guard pair.isValid, video.pixel.chromaSiting == .unknown,
                  video.pixel.chromaSubsampling == .yuv420,
                  video.scan.fieldCount == 2, video.scan.cadence == .interlaced,
                  video.scan.dominance == .topFieldFirst || video.scan.dominance == .bottomFieldFirst else {
                throw CanonicalMediaStateV4Error.invalidVideoSemantics(trackID)
            }
        }
        switch video.scan.fieldCount {
        case 1:
            guard video.scan.dominance == .none,
                  video.scan.cadence == .progressive else {
                throw CanonicalMediaStateV4Error.invalidVideoSemantics(trackID)
            }
        case 2:
            guard video.scan.dominance != .none,
                  video.scan.cadence != .progressive else {
                throw CanonicalMediaStateV4Error.invalidVideoSemantics(trackID)
            }
        default:
            throw CanonicalMediaStateV4Error.invalidVideoSemantics(trackID)
        }
    }

    private static func isStableIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte)
                || (0x41...0x5a).contains(byte)
                || (0x61...0x7a).contains(byte)
                || [0x2d, 0x2e, 0x3a, 0x5f].contains(byte)
        }
    }
}

private struct CanonicalFieldCodingKeyV4: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension CanonicalFieldChromaSitingV4 {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CanonicalFieldCodingKeyV4.self)
        guard Set(values.allKeys.map(\.stringValue)) == ["schemaID", "top", "bottom"] else {
            throw CanonicalMediaStateV4Error.invalidVideoSemantics("field_chroma_keys")
        }
        schemaID = try values.decode(String.self, forKey: .init(stringValue: "schemaID")!)
        top = try values.decode(CanonicalChromaSitingV4.self, forKey: .init(stringValue: "top")!)
        bottom = try values.decode(CanonicalChromaSitingV4.self, forKey: .init(stringValue: "bottom")!)
        guard isValid else {
            throw CanonicalMediaStateV4Error.invalidVideoSemantics("field_chroma_pair")
        }
    }
}

extension CanonicalPixelStateV4 {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CanonicalFieldCodingKeyV4.self)
        func key(_ value: String) -> CanonicalFieldCodingKeyV4 {
            CanonicalFieldCodingKeyV4(stringValue: value)!
        }
        formatID = try values.decode(String.self, forKey: key("formatID"))
        bitDepth = try values.decode(UInt8.self, forKey: key("bitDepth"))
        range = try values.decode(CanonicalPixelRangeV4.self, forKey: key("range"))
        chromaSubsampling = try values.decode(CanonicalChromaSubsamplingV4.self, forKey: key("chromaSubsampling"))
        chromaSiting = try values.decode(CanonicalChromaSitingV4.self, forKey: key("chromaSiting"))
        alphaModel = try values.decode(CanonicalAlphaModelV4.self, forKey: key("alphaModel"))
        if values.contains(key("fieldChromaSiting")) {
            guard Set(values.allKeys.map(\.stringValue)) == ["formatID", "bitDepth", "range", "chromaSubsampling", "chromaSiting", "alphaModel", "fieldChromaSiting"] else {
                throw CanonicalMediaStateV4Error.invalidVideoSemantics("field_chroma_pixel_keys")
            }
            fieldChromaSiting = try values.decode(CanonicalFieldChromaSitingV4.self, forKey: key("fieldChromaSiting"))
        } else {
            fieldChromaSiting = nil
        }
    }
}
