import CryptoKit
import Foundation

// This single-file contract is intentionally self-contained so R12 route and
// checkpoint code can share one immutable media vocabulary.
// swiftlint:disable file_length

enum R12PixelStorageV2: String, CaseIterable, Encodable, Hashable, Sendable {
    case nv12
    case p010
    case planar422 = "planar_422"
    case planar444 = "planar_444"
}

enum R12BitDepthV2: Int, CaseIterable, Encodable, Hashable, Sendable {
    case eight = 8
    case ten = 10
}

enum R12ChromaSubsamplingV2: String, CaseIterable, Encodable, Hashable, Sendable {
    case yuv420 = "4:2:0"
    case yuv422 = "4:2:2"
    case yuv444 = "4:4:4"
}

enum R12CodeRangeV2: String, CaseIterable, Encodable, Hashable, Sendable {
    case video
    case full
}

enum R12ColorPrimariesV2: String, CaseIterable, Encodable, Hashable, Sendable {
    case bt709 = "bt_709"
    case bt2020 = "bt_2020"
}

enum R12TransferFunctionV2: String, CaseIterable, Encodable, Hashable, Sendable {
    case bt709 = "bt_709"
    case pq
    case hlg

    var isHDR: Bool {
        self == .pq || self == .hlg
    }
}

enum R12YCbCrMatrixV2: String, CaseIterable, Encodable, Hashable, Sendable {
    case bt709 = "bt_709"
    case bt2020NCL = "bt_2020_ncl"
}

enum R12ChromaSitingV2: String, CaseIterable, Encodable, Hashable, Sendable {
    case bottom
    case bottomLeft = "bottom_left"
    case center
    case left
    case top
    case topLeft = "top_left"
    case notApplicable = "not_applicable"
}

enum R12ScanStructureV2: String, CaseIterable, Encodable, Hashable, Sendable {
    case progressive
    case interlacedTopFieldFirst = "interlaced_top_field_first"
    case interlacedBottomFieldFirst = "interlaced_bottom_field_first"

    var isInterlaced: Bool {
        self != .progressive
    }
}

enum R12DeinterlacePolicyV2: String, CaseIterable, Encodable, Hashable, Sendable {
    case notRequired = "not_required"
    case preserveInterlaced = "preserve_interlaced"
    case requiredBeforeUpscale = "required_before_upscale"
}

enum R12AlphaSemanticsV2: String, CaseIterable, Encodable, Hashable, Sendable {
    case none
    case straight
    case premultiplied
}

enum R12PreservationRuleV2: String, Encodable, Hashable, Sendable {
    case exact
    case preserveIfPresent = "preserve_if_present"
    case notApplicable = "not_applicable"
}

enum R12QualityScopeV2: String, Encodable, Hashable, Sendable {
    case structuralIntegrityOnly = "structural_integrity_only"
}

enum R12SoftwareFunctionRequirementV2: String, Encodable, Hashable, Sendable {
    case required
    case notApplicable = "not_applicable"
}

enum R12EvidenceBasisV2: String, Encodable, Hashable, Sendable {
    case deterministicContract = "deterministic_contract"
    case nativeObserved = "native_observed"
}

enum R12AuthorizationV2: String, Encodable, Hashable, Sendable {
    case notAuthorized = "not_authorized"
}

enum R12MarketClaimV2: String, Encodable, Hashable, Sendable {
    case noMarketClaim = "no_market_claim"
}

enum R12MetadataFieldV2: String, CaseIterable, Equatable, Sendable {
    case colorMetadata = "color_metadata"
    case hdrStaticMetadata = "hdr_static_metadata"
    case hdrDynamicMetadata = "hdr_dynamic_metadata"
    case audioMetadata = "audio_metadata"
    case orientation
    case cleanAperture = "clean_aperture"
    case pixelAspectRatio = "pixel_aspect_ratio"
    case displayMetadata = "mastering_display"
    case contentLightLevel = "content_light_level"
    case subtitles
    case timecode
    case containerMetadata = "container_metadata"
}

enum R12StructuralQualityFieldV2: String, CaseIterable, Equatable, Sendable {
    case scope
    case frameCount = "frame_count"
    case presentationTimeline = "presentation_timeline"
    case audioTracks = "audio_tracks"
    case subtitleTracks = "subtitle_tracks"
    case metadata
    case alpha
    case outputReopen = "output_reopen"
    case exactDimensions = "exact_dimensions"
    case exactPlaneGeometry = "exact_plane_geometry"
    case deterministicDigest = "deterministic_digest"
    case visibleFallback = "visible_fallback"
    case resumeEquivalence = "resume_equivalence"
}

enum R12MediaFormatContractErrorV2: Error, Equatable, Sendable {
    case invalidResolution(width: Int, height: Int)
    case incompatibleStorage(
        storage: R12PixelStorageV2,
        bitDepth: R12BitDepthV2,
        subsampling: R12ChromaSubsamplingV2
    )
    case invalidChromaSiting(
        subsampling: R12ChromaSubsamplingV2,
        siting: R12ChromaSitingV2
    )
    case invalidColorMatrix(
        primaries: R12ColorPrimariesV2,
        matrix: R12YCbCrMatrixV2
    )
    case hdrRequiresTenBit(R12TransferFunctionV2)
    case invalidScanPolicy(
        scan: R12ScanStructureV2,
        policy: R12DeinterlacePolicyV2
    )
    case alphaRequiresPlanar444(R12AlphaSemanticsV2)
    case invalidSubsampledDimensions(
        subsampling: R12ChromaSubsamplingV2,
        width: Int,
        height: Int
    )
    case metadataRuleMismatch(R12MetadataFieldV2)
    case structuralQualityMismatch(R12StructuralQualityFieldV2)
    case invalidIdentifier(field: String, value: String)
    case invalidSHA256(field: String, value: String)
    case noSupportedFormats
    case duplicateSupportedFormat(String)
    case evidenceBasisMismatch
    case unsupportedFormat(String)

    var machineCode: String {
        switch self {
        case .invalidResolution: "invalid_resolution"
        case .incompatibleStorage: "incompatible_storage"
        case .invalidChromaSiting: "invalid_chroma_siting"
        case .invalidColorMatrix: "invalid_color_matrix"
        case .hdrRequiresTenBit: "hdr_requires_ten_bit"
        case .invalidScanPolicy: "invalid_scan_policy"
        case .alphaRequiresPlanar444: "alpha_requires_planar_444"
        case .invalidSubsampledDimensions: "invalid_subsampled_dimensions"
        case .metadataRuleMismatch(let field): "metadata_rule_mismatch_\(field.rawValue)"
        case .structuralQualityMismatch(let field):
            "structural_quality_mismatch_\(field.rawValue)"
        case .invalidIdentifier(let field, _): "invalid_identifier_\(field)"
        case .invalidSHA256(let field, _): "invalid_sha256_\(field)"
        case .noSupportedFormats: "no_supported_formats"
        case .duplicateSupportedFormat: "duplicate_supported_format"
        case .evidenceBasisMismatch: "evidence_basis_mismatch"
        case .unsupportedFormat: "unsupported_format"
        }
    }
}

struct R12ResolutionV2: Encodable, Hashable, Sendable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw R12MediaFormatContractErrorV2.invalidResolution(
                width: width,
                height: height
            )
        }
        self.width = width
        self.height = height
    }
}

struct R12MediaSamplingV2: Encodable, Hashable, Sendable {
    let storage: R12PixelStorageV2
    let bitDepth: R12BitDepthV2
    let chromaSubsampling: R12ChromaSubsamplingV2
    let codeRange: R12CodeRangeV2
    let chromaSiting: R12ChromaSitingV2

    enum CodingKeys: String, CodingKey {
        case storage
        case bitDepth = "bit_depth"
        case chromaSubsampling = "chroma_subsampling"
        case codeRange = "code_range"
        case chromaSiting = "chroma_siting"
    }

    init(
        storage: R12PixelStorageV2,
        bitDepth: R12BitDepthV2,
        chromaSubsampling: R12ChromaSubsamplingV2,
        codeRange: R12CodeRangeV2,
        chromaSiting: R12ChromaSitingV2
    ) throws {
        let storageIsValid: Bool
        switch storage {
        case .nv12:
            storageIsValid = bitDepth == .eight && chromaSubsampling == .yuv420
        case .p010:
            storageIsValid = bitDepth == .ten && chromaSubsampling == .yuv420
        case .planar422:
            storageIsValid = chromaSubsampling == .yuv422
        case .planar444:
            storageIsValid = chromaSubsampling == .yuv444
        }
        guard storageIsValid else {
            throw R12MediaFormatContractErrorV2.incompatibleStorage(
                storage: storage,
                bitDepth: bitDepth,
                subsampling: chromaSubsampling
            )
        }

        let sitingIsValid = chromaSubsampling == .yuv444
            ? chromaSiting == .notApplicable
            : chromaSiting != .notApplicable
        guard sitingIsValid else {
            throw R12MediaFormatContractErrorV2.invalidChromaSiting(
                subsampling: chromaSubsampling,
                siting: chromaSiting
            )
        }

        self.storage = storage
        self.bitDepth = bitDepth
        self.chromaSubsampling = chromaSubsampling
        self.codeRange = codeRange
        self.chromaSiting = chromaSiting
    }

    func validateInvariants() throws {
        _ = try R12MediaSamplingV2(
            storage: storage,
            bitDepth: bitDepth,
            chromaSubsampling: chromaSubsampling,
            codeRange: codeRange,
            chromaSiting: chromaSiting
        )
    }
}

struct R12ColorContractV2: Encodable, Hashable, Sendable {
    let colorPrimaries: R12ColorPrimariesV2
    let transferFunction: R12TransferFunctionV2
    let yCbCrMatrix: R12YCbCrMatrixV2

    enum CodingKeys: String, CodingKey {
        case colorPrimaries = "color_primaries"
        case transferFunction = "transfer_function"
        case yCbCrMatrix = "ycbcr_matrix"
    }

    init(
        colorPrimaries: R12ColorPrimariesV2,
        transferFunction: R12TransferFunctionV2,
        yCbCrMatrix: R12YCbCrMatrixV2
    ) throws {
        let expectedMatrix: R12YCbCrMatrixV2 = colorPrimaries == .bt709
            ? .bt709
            : .bt2020NCL
        guard yCbCrMatrix == expectedMatrix else {
            throw R12MediaFormatContractErrorV2.invalidColorMatrix(
                primaries: colorPrimaries,
                matrix: yCbCrMatrix
            )
        }
        if transferFunction.isHDR, colorPrimaries != .bt2020 {
            throw R12MediaFormatContractErrorV2.invalidColorMatrix(
                primaries: colorPrimaries,
                matrix: yCbCrMatrix
            )
        }
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
    }

    func validateInvariants() throws {
        _ = try R12ColorContractV2(
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix
        )
    }

    static let sdrBT709 = makeStatic(
        colorPrimaries: .bt709,
        transferFunction: .bt709,
        yCbCrMatrix: .bt709
    )

    static func hdrBT2020(
        transferFunction: R12TransferFunctionV2
    ) throws -> R12ColorContractV2 {
        guard transferFunction.isHDR else {
            throw R12MediaFormatContractErrorV2.invalidColorMatrix(
                primaries: .bt2020,
                matrix: .bt2020NCL
            )
        }
        return try R12ColorContractV2(
            colorPrimaries: .bt2020,
            transferFunction: transferFunction,
            yCbCrMatrix: .bt2020NCL
        )
    }

    private static func makeStatic(
        colorPrimaries: R12ColorPrimariesV2,
        transferFunction: R12TransferFunctionV2,
        yCbCrMatrix: R12YCbCrMatrixV2
    ) -> R12ColorContractV2 {
        do {
            return try R12ColorContractV2(
                colorPrimaries: colorPrimaries,
                transferFunction: transferFunction,
                yCbCrMatrix: yCbCrMatrix
            )
        } catch {
            preconditionFailure("Static R12 color contract must be valid: \(error)")
        }
    }
}

struct R12ScanContractV2: Encodable, Hashable, Sendable {
    let scanStructure: R12ScanStructureV2
    let deinterlacePolicy: R12DeinterlacePolicyV2

    enum CodingKeys: String, CodingKey {
        case scanStructure = "scan_structure"
        case deinterlacePolicy = "deinterlace_policy"
    }

    init(
        scanStructure: R12ScanStructureV2,
        deinterlacePolicy: R12DeinterlacePolicyV2
    ) throws {
        let valid = scanStructure == .progressive
            ? deinterlacePolicy == .notRequired
            : deinterlacePolicy != .notRequired
        guard valid else {
            throw R12MediaFormatContractErrorV2.invalidScanPolicy(
                scan: scanStructure,
                policy: deinterlacePolicy
            )
        }
        self.scanStructure = scanStructure
        self.deinterlacePolicy = deinterlacePolicy
    }

    func validateInvariants() throws {
        _ = try R12ScanContractV2(
            scanStructure: scanStructure,
            deinterlacePolicy: deinterlacePolicy
        )
    }

    static let progressive = makeStatic(
        scanStructure: .progressive,
        deinterlacePolicy: .notRequired
    )

    private static func makeStatic(
        scanStructure: R12ScanStructureV2,
        deinterlacePolicy: R12DeinterlacePolicyV2
    ) -> R12ScanContractV2 {
        do {
            return try R12ScanContractV2(
                scanStructure: scanStructure,
                deinterlacePolicy: deinterlacePolicy
            )
        } catch {
            preconditionFailure("Static R12 scan contract must be valid: \(error)")
        }
    }
}

struct R12MediaFormatDescriptorV2: Encodable, Hashable, Sendable {
    let sampling: R12MediaSamplingV2
    let color: R12ColorContractV2
    let scan: R12ScanContractV2
    let alphaSemantics: R12AlphaSemanticsV2

    enum CodingKeys: String, CodingKey {
        case sampling
        case color
        case scan
        case alphaSemantics = "alpha_semantics"
    }

    init(
        sampling: R12MediaSamplingV2,
        color: R12ColorContractV2,
        scan: R12ScanContractV2,
        alphaSemantics: R12AlphaSemanticsV2
    ) throws {
        if color.transferFunction.isHDR, sampling.bitDepth != .ten {
            throw R12MediaFormatContractErrorV2.hdrRequiresTenBit(
                color.transferFunction
            )
        }
        if alphaSemantics != .none, sampling.storage != .planar444 {
            throw R12MediaFormatContractErrorV2.alphaRequiresPlanar444(
                alphaSemantics
            )
        }
        self.sampling = sampling
        self.color = color
        self.scan = scan
        self.alphaSemantics = alphaSemantics
    }

    func validateInvariants() throws {
        try sampling.validateInvariants()
        try color.validateInvariants()
        try scan.validateInvariants()
        _ = try R12MediaFormatDescriptorV2(
            sampling: sampling,
            color: color,
            scan: scan,
            alphaSemantics: alphaSemantics
        )
    }

    init(
        storage: R12PixelStorageV2,
        bitDepth: R12BitDepthV2,
        chromaSubsampling: R12ChromaSubsamplingV2,
        codeRange: R12CodeRangeV2,
        colorPrimaries: R12ColorPrimariesV2,
        transferFunction: R12TransferFunctionV2,
        yCbCrMatrix: R12YCbCrMatrixV2,
        chromaSiting: R12ChromaSitingV2,
        scanStructure: R12ScanStructureV2,
        deinterlacePolicy: R12DeinterlacePolicyV2,
        alphaSemantics: R12AlphaSemanticsV2
    ) throws {
        try self.init(
            sampling: R12MediaSamplingV2(
                storage: storage,
                bitDepth: bitDepth,
                chromaSubsampling: chromaSubsampling,
                codeRange: codeRange,
                chromaSiting: chromaSiting
            ),
            color: R12ColorContractV2(
                colorPrimaries: colorPrimaries,
                transferFunction: transferFunction,
                yCbCrMatrix: yCbCrMatrix
            ),
            scan: R12ScanContractV2(
                scanStructure: scanStructure,
                deinterlacePolicy: deinterlacePolicy
            ),
            alphaSemantics: alphaSemantics
        )
    }

    var canonicalData: Data {
        R12CanonicalEncodingV2.data(self)
    }

    var canonicalSHA256: String {
        R12CanonicalEncodingV2.sha256(canonicalData)
    }

    func validate(resolution: R12ResolutionV2) throws {
        let valid: Bool
        switch sampling.chromaSubsampling {
        case .yuv420:
            valid = resolution.width.isMultiple(of: 2)
                && resolution.height.isMultiple(of: 2)
        case .yuv422:
            valid = resolution.width.isMultiple(of: 2)
        case .yuv444:
            valid = true
        }
        guard valid else {
            throw R12MediaFormatContractErrorV2.invalidSubsampledDimensions(
                subsampling: sampling.chromaSubsampling,
                width: resolution.width,
                height: resolution.height
            )
        }
    }
}

struct R12MetadataPreservationContractV2: Encodable, Hashable, Sendable {
    let colorMetadata: R12PreservationRuleV2
    let hdrStaticMetadata: R12PreservationRuleV2
    let hdrDynamicMetadata: R12PreservationRuleV2
    let audioMetadata: R12PreservationRuleV2
    let orientation: R12PreservationRuleV2
    let cleanAperture: R12PreservationRuleV2
    let pixelAspectRatio: R12PreservationRuleV2
    let displayMetadata: R12PreservationRuleV2
    let contentLightLevel: R12PreservationRuleV2
    let subtitles: R12PreservationRuleV2
    let timecode: R12PreservationRuleV2
    let containerMetadata: R12PreservationRuleV2

    enum CodingKeys: String, CodingKey {
        case colorMetadata = "color_metadata"
        case hdrStaticMetadata = "hdr_static_metadata"
        case hdrDynamicMetadata = "hdr_dynamic_metadata"
        case audioMetadata = "audio_metadata"
        case orientation
        case cleanAperture = "clean_aperture"
        case pixelAspectRatio = "pixel_aspect_ratio"
        case displayMetadata = "mastering_display"
        case contentLightLevel = "content_light_level"
        case subtitles
        case timecode
        case containerMetadata = "container_metadata"
    }

    static let sdrPreserving = R12MetadataPreservationContractV2(
        colorMetadata: .exact,
        hdrStaticMetadata: .notApplicable,
        hdrDynamicMetadata: .notApplicable,
        audioMetadata: .preserveIfPresent,
        orientation: .preserveIfPresent,
        cleanAperture: .preserveIfPresent,
        pixelAspectRatio: .preserveIfPresent,
        displayMetadata: .notApplicable,
        contentLightLevel: .notApplicable,
        subtitles: .preserveIfPresent,
        timecode: .preserveIfPresent,
        containerMetadata: .preserveIfPresent
    )

    static let hdrPreserving = R12MetadataPreservationContractV2(
        colorMetadata: .exact,
        hdrStaticMetadata: .preserveIfPresent,
        hdrDynamicMetadata: .preserveIfPresent,
        audioMetadata: .preserveIfPresent,
        orientation: .preserveIfPresent,
        cleanAperture: .preserveIfPresent,
        pixelAspectRatio: .preserveIfPresent,
        displayMetadata: .preserveIfPresent,
        contentLightLevel: .preserveIfPresent,
        subtitles: .preserveIfPresent,
        timecode: .preserveIfPresent,
        containerMetadata: .preserveIfPresent
    )
}

struct R12StructuralQualityContractV2: Encodable, Hashable, Sendable {
    let scope: R12QualityScopeV2
    let frameCount: R12PreservationRuleV2
    let presentationTimeline: R12PreservationRuleV2
    let audioTracks: R12PreservationRuleV2
    let subtitleTracks: R12PreservationRuleV2
    let metadata: R12PreservationRuleV2
    let alpha: R12PreservationRuleV2
    let outputReopen: R12PreservationRuleV2
    let exactDimensions: R12SoftwareFunctionRequirementV2
    let exactPlaneGeometry: R12SoftwareFunctionRequirementV2
    let deterministicDigest: R12SoftwareFunctionRequirementV2
    let visibleFallback: R12SoftwareFunctionRequirementV2
    let resumeEquivalence: R12SoftwareFunctionRequirementV2

    enum CodingKeys: String, CodingKey {
        case scope
        case frameCount = "frame_count"
        case presentationTimeline = "presentation_timeline"
        case audioTracks = "audio_tracks"
        case subtitleTracks = "subtitle_tracks"
        case metadata
        case alpha
        case outputReopen = "output_reopen"
        case exactDimensions = "exact_dimensions"
        case exactPlaneGeometry = "exact_plane_geometry"
        case deterministicDigest = "deterministic_digest"
        case visibleFallback = "visible_fallback"
        case resumeEquivalence = "resume_equivalence"
    }

    init(
        scope: R12QualityScopeV2 = .structuralIntegrityOnly,
        frameCount: R12PreservationRuleV2 = .exact,
        presentationTimeline: R12PreservationRuleV2 = .exact,
        audioTracks: R12PreservationRuleV2 = .preserveIfPresent,
        subtitleTracks: R12PreservationRuleV2 = .preserveIfPresent,
        metadata: R12PreservationRuleV2 = .exact,
        alpha: R12PreservationRuleV2,
        outputReopen: R12PreservationRuleV2 = .exact,
        exactDimensions: R12SoftwareFunctionRequirementV2 = .required,
        exactPlaneGeometry: R12SoftwareFunctionRequirementV2 = .required,
        deterministicDigest: R12SoftwareFunctionRequirementV2 = .required,
        visibleFallback: R12SoftwareFunctionRequirementV2 = .required,
        resumeEquivalence: R12SoftwareFunctionRequirementV2 = .required
    ) throws {
        try Self.require(
            scope == .structuralIntegrityOnly,
            field: .scope
        )
        try Self.require(frameCount == .exact, field: .frameCount)
        try Self.require(
            presentationTimeline == .exact,
            field: .presentationTimeline
        )
        try Self.require(
            audioTracks == .preserveIfPresent,
            field: .audioTracks
        )
        try Self.require(
            subtitleTracks == .preserveIfPresent,
            field: .subtitleTracks
        )
        try Self.require(metadata == .exact, field: .metadata)
        try Self.require(
            alpha == .exact || alpha == .notApplicable,
            field: .alpha
        )
        try Self.require(outputReopen == .exact, field: .outputReopen)
        try Self.require(
            exactDimensions == .required,
            field: .exactDimensions
        )
        try Self.require(
            exactPlaneGeometry == .required,
            field: .exactPlaneGeometry
        )
        try Self.require(
            deterministicDigest == .required,
            field: .deterministicDigest
        )
        try Self.require(
            visibleFallback == .required,
            field: .visibleFallback
        )
        try Self.require(
            resumeEquivalence == .required,
            field: .resumeEquivalence
        )
        self.scope = scope
        self.frameCount = frameCount
        self.presentationTimeline = presentationTimeline
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.metadata = metadata
        self.alpha = alpha
        self.outputReopen = outputReopen
        self.exactDimensions = exactDimensions
        self.exactPlaneGeometry = exactPlaneGeometry
        self.deterministicDigest = deterministicDigest
        self.visibleFallback = visibleFallback
        self.resumeEquivalence = resumeEquivalence
    }

    static func preserving(alpha hasAlpha: Bool) -> R12StructuralQualityContractV2 {
        do {
            return try R12StructuralQualityContractV2(
                alpha: hasAlpha ? .exact : .notApplicable
            )
        } catch {
            preconditionFailure(
                "Static R12 quality contract must be valid: \(error)"
            )
        }
    }

    private static func require(
        _ condition: Bool,
        field: R12StructuralQualityFieldV2
    ) throws {
        guard condition else {
            throw R12MediaFormatContractErrorV2.structuralQualityMismatch(field)
        }
    }
}

struct R12FormatEvidenceV2: Encodable, Hashable, Sendable {
    let basis: R12EvidenceBasisV2
    let fixtureID: String?
    let nativeObservationSHA256: String?

    enum CodingKeys: String, CodingKey {
        case basis
        case fixtureID = "fixture_id"
        case nativeObservationSHA256 = "native_observation_sha256"
    }

    private init(
        basis: R12EvidenceBasisV2,
        fixtureID: String?,
        nativeObservationSHA256: String?
    ) {
        self.basis = basis
        self.fixtureID = fixtureID
        self.nativeObservationSHA256 = nativeObservationSHA256
    }

    static func deterministicContract(
        fixtureID: String
    ) throws -> R12FormatEvidenceV2 {
        R12FormatEvidenceV2(
            basis: .deterministicContract,
            fixtureID: try R12ContractValidationV2.identifier(
                fixtureID,
                field: "fixture_id"
            ),
            nativeObservationSHA256: nil
        )
    }

    static func nativeObserved(
        observationSHA256: String
    ) throws -> R12FormatEvidenceV2 {
        R12FormatEvidenceV2(
            basis: .nativeObserved,
            fixtureID: nil,
            nativeObservationSHA256: try R12ContractValidationV2.sha256(
                observationSHA256,
                field: "native_observation"
            )
        )
    }
}

struct R12AuthorityBoundaryV2: Encodable, Hashable, Sendable {
    let productAdmission: R12AuthorizationV2
    let productionAutoMode: R12AuthorizationV2
    let releasePublication: R12AuthorizationV2
    let marketClaim: R12MarketClaimV2

    enum CodingKeys: String, CodingKey {
        case productAdmission = "product_admission"
        case productionAutoMode = "production_auto_mode"
        case releasePublication = "release_publication"
        case marketClaim = "market_claim"
    }

    static let formatExpansionOnly = R12AuthorityBoundaryV2(
        productAdmission: .notAuthorized,
        productionAutoMode: .notAuthorized,
        releasePublication: .notAuthorized,
        marketClaim: .noMarketClaim
    )
}

struct R12MediaFormatContractV2: Encodable, Hashable, Sendable {
    static let schemaVersion = "2.0.0"
    static let artifactKind = "r12_media_format_contract"

    let format: R12MediaFormatDescriptorV2
    let metadata: R12MetadataPreservationContractV2
    let quality: R12StructuralQualityContractV2
    let evidence: R12FormatEvidenceV2
    let authority: R12AuthorityBoundaryV2

    enum CodingKeys: String, CodingKey {
        case artifactKind = "artifact_kind"
        case schemaVersion = "schema_version"
        case format
        case metadata
        case quality
        case evidence
        case authority
    }

    init(
        format: R12MediaFormatDescriptorV2,
        metadata: R12MetadataPreservationContractV2,
        quality: R12StructuralQualityContractV2,
        evidence: R12FormatEvidenceV2
    ) throws {
        try format.validateInvariants()
        try Self.validate(metadata: metadata, for: format)
        try Self.validate(quality: quality, for: format)
        self.format = format
        self.metadata = metadata
        self.quality = quality
        self.evidence = evidence
        self.authority = .formatExpansionOnly
    }

    var canonicalData: Data {
        R12CanonicalEncodingV2.data(self)
    }

    var canonicalSHA256: String {
        R12CanonicalEncodingV2.sha256(canonicalData)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.artifactKind, forKey: .artifactKind)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(format, forKey: .format)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(quality, forKey: .quality)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(authority, forKey: .authority)
    }

    private static func validate(
        metadata: R12MetadataPreservationContractV2,
        for format: R12MediaFormatDescriptorV2
    ) throws {
        try require(
            metadata.colorMetadata,
            equals: .exact,
            field: .colorMetadata
        )
        let expectedHDRRule: R12PreservationRuleV2 =
            format.color.transferFunction.isHDR ? .preserveIfPresent : .notApplicable
        try require(
            metadata.hdrStaticMetadata,
            equals: expectedHDRRule,
            field: .hdrStaticMetadata
        )
        try require(
            metadata.hdrDynamicMetadata,
            equals: expectedHDRRule,
            field: .hdrDynamicMetadata
        )
        try require(
            metadata.audioMetadata,
            equals: .preserveIfPresent,
            field: .audioMetadata
        )
        try require(
            metadata.orientation,
            equals: .preserveIfPresent,
            field: .orientation
        )
        try require(
            metadata.cleanAperture,
            equals: .preserveIfPresent,
            field: .cleanAperture
        )
        try require(
            metadata.pixelAspectRatio,
            equals: .preserveIfPresent,
            field: .pixelAspectRatio
        )
        try require(
            metadata.displayMetadata,
            equals: expectedHDRRule,
            field: .displayMetadata
        )
        try require(
            metadata.contentLightLevel,
            equals: expectedHDRRule,
            field: .contentLightLevel
        )
        try require(
            metadata.subtitles,
            equals: .preserveIfPresent,
            field: .subtitles
        )
        try require(
            metadata.timecode,
            equals: .preserveIfPresent,
            field: .timecode
        )
        try require(
            metadata.containerMetadata,
            equals: .preserveIfPresent,
            field: .containerMetadata
        )
    }

    private static func validate(
        quality: R12StructuralQualityContractV2,
        for format: R12MediaFormatDescriptorV2
    ) throws {
        let expectedAlpha: R12PreservationRuleV2 = format.alphaSemantics == .none
            ? .notApplicable
            : .exact
        let invariants: [(R12StructuralQualityFieldV2, Bool)] = [
            (.scope, quality.scope == .structuralIntegrityOnly),
            (.frameCount, quality.frameCount == .exact),
            (.presentationTimeline, quality.presentationTimeline == .exact),
            (.audioTracks, quality.audioTracks == .preserveIfPresent),
            (.subtitleTracks, quality.subtitleTracks == .preserveIfPresent),
            (.metadata, quality.metadata == .exact),
            (.alpha, quality.alpha == expectedAlpha),
            (.outputReopen, quality.outputReopen == .exact),
            (.exactDimensions, quality.exactDimensions == .required),
            (.exactPlaneGeometry, quality.exactPlaneGeometry == .required),
            (.deterministicDigest, quality.deterministicDigest == .required),
            (.visibleFallback, quality.visibleFallback == .required),
            (.resumeEquivalence, quality.resumeEquivalence == .required)
        ]
        if let mismatch = invariants.first(where: { !$0.1 }) {
            throw R12MediaFormatContractErrorV2
                .structuralQualityMismatch(mismatch.0)
        }
    }

    private static func require(
        _ actual: R12PreservationRuleV2,
        equals expected: R12PreservationRuleV2,
        field: R12MetadataFieldV2
    ) throws {
        guard actual == expected else {
            throw R12MediaFormatContractErrorV2.metadataRuleMismatch(field)
        }
    }
}

struct R12BackendFormatCapabilityV2: Encodable, Hashable, Sendable {
    static let schemaVersion = "2.0.0"
    static let artifactKind = "r12_backend_format_capability"

    let backendID: String
    let supportedFormats: [R12MediaFormatContractV2]
    let evidence: R12FormatEvidenceV2
    let authority: R12AuthorityBoundaryV2

    enum CodingKeys: String, CodingKey {
        case artifactKind = "artifact_kind"
        case schemaVersion = "schema_version"
        case backendID = "backend_id"
        case supportedFormats = "supported_formats"
        case evidence
        case authority
    }

    init(
        backendID: String,
        supportedFormats: [R12MediaFormatContractV2],
        evidence: R12FormatEvidenceV2
    ) throws {
        let backendID = try R12ContractValidationV2.identifier(
            backendID,
            field: "backend_id"
        )
        guard !supportedFormats.isEmpty else {
            throw R12MediaFormatContractErrorV2.noSupportedFormats
        }
        let sorted = supportedFormats.sorted {
            $0.canonicalSHA256 < $1.canonicalSHA256
        }
        let hashes = sorted.map(\.canonicalSHA256)
        guard Set(hashes).count == hashes.count else {
            let duplicate = hashes.first { hash in
                hashes.filter { $0 == hash }.count > 1
            } ?? ""
            throw R12MediaFormatContractErrorV2.duplicateSupportedFormat(duplicate)
        }
        guard sorted.allSatisfy({ $0.evidence.basis == evidence.basis }) else {
            throw R12MediaFormatContractErrorV2.evidenceBasisMismatch
        }
        self.backendID = backendID
        self.supportedFormats = sorted
        self.evidence = evidence
        self.authority = .formatExpansionOnly
    }

    var canonicalData: Data {
        R12CanonicalEncodingV2.data(self)
    }

    var canonicalSHA256: String {
        R12CanonicalEncodingV2.sha256(canonicalData)
    }

    func supports(_ contract: R12MediaFormatContractV2) -> Bool {
        supportedFormats.contains(contract)
    }

    func supports(_ format: R12MediaFormatDescriptorV2) -> Bool {
        supportedFormats.contains { $0.format == format }
    }

    func requireSupport(for contract: R12MediaFormatContractV2) throws {
        guard supports(contract) else {
            throw R12MediaFormatContractErrorV2.unsupportedFormat(
                contract.canonicalSHA256
            )
        }
    }

    func requireSupport(for format: R12MediaFormatDescriptorV2) throws {
        guard supports(format) else {
            throw R12MediaFormatContractErrorV2.unsupportedFormat(
                format.canonicalSHA256
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.artifactKind, forKey: .artifactKind)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(backendID, forKey: .backendID)
        try container.encode(supportedFormats, forKey: .supportedFormats)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(authority, forKey: .authority)
    }
}

enum R12MediaFormatFixtureCatalogV2 {
    static let nv12SDR = make(
        fixtureID: "r12-nv12-sdr",
        sampling: sampling(
            storage: .nv12,
            bitDepth: .eight,
            subsampling: .yuv420,
            range: .video,
            siting: .left
        ),
        color: .sdrBT709,
        scan: .progressive,
        alpha: .none,
        metadata: .sdrPreserving
    )

    static let p010PQ = make(
        fixtureID: "r12-p010-pq",
        sampling: sampling(
            storage: .p010,
            bitDepth: .ten,
            subsampling: .yuv420,
            range: .video,
            siting: .left
        ),
        color: hdrColor(.pq),
        scan: .progressive,
        alpha: .none,
        metadata: .hdrPreserving
    )

    static let p010HLG = make(
        fixtureID: "r12-p010-hlg",
        sampling: sampling(
            storage: .p010,
            bitDepth: .ten,
            subsampling: .yuv420,
            range: .video,
            siting: .left
        ),
        color: hdrColor(.hlg),
        scan: .progressive,
        alpha: .none,
        metadata: .hdrPreserving
    )

    static let planar422SDR = make(
        fixtureID: "r12-planar-422-sdr",
        sampling: sampling(
            storage: .planar422,
            bitDepth: .eight,
            subsampling: .yuv422,
            range: .video,
            siting: .left
        ),
        color: .sdrBT709,
        scan: .progressive,
        alpha: .none,
        metadata: .sdrPreserving
    )

    static let planar444HDR = make(
        fixtureID: "r12-planar-444-hdr",
        sampling: sampling(
            storage: .planar444,
            bitDepth: .ten,
            subsampling: .yuv444,
            range: .full,
            siting: .notApplicable
        ),
        color: hdrColor(.pq),
        scan: .progressive,
        alpha: .none,
        metadata: .hdrPreserving
    )

    static let interlacedDeinterlace = make(
        fixtureID: "r12-interlaced-deinterlace",
        sampling: sampling(
            storage: .nv12,
            bitDepth: .eight,
            subsampling: .yuv420,
            range: .video,
            siting: .left
        ),
        color: .sdrBT709,
        scan: scan(
            structure: .interlacedTopFieldFirst,
            policy: .requiredBeforeUpscale
        ),
        alpha: .none,
        metadata: .sdrPreserving
    )

    static let planar444Alpha = make(
        fixtureID: "r12-planar-444-alpha",
        sampling: sampling(
            storage: .planar444,
            bitDepth: .eight,
            subsampling: .yuv444,
            range: .full,
            siting: .notApplicable
        ),
        color: .sdrBT709,
        scan: .progressive,
        alpha: .straight,
        metadata: .sdrPreserving
    )

    static let all: [R12MediaFormatContractV2] = [
        interlacedDeinterlace,
        nv12SDR,
        p010HLG,
        p010PQ,
        planar422SDR,
        planar444Alpha,
        planar444HDR
    ].sorted { $0.canonicalSHA256 < $1.canonicalSHA256 }

    private static func make(
        fixtureID: String,
        sampling: R12MediaSamplingV2,
        color: R12ColorContractV2,
        scan: R12ScanContractV2,
        alpha: R12AlphaSemanticsV2,
        metadata: R12MetadataPreservationContractV2
    ) -> R12MediaFormatContractV2 {
        do {
            let format = try R12MediaFormatDescriptorV2(
                sampling: sampling,
                color: color,
                scan: scan,
                alphaSemantics: alpha
            )
            return try R12MediaFormatContractV2(
                format: format,
                metadata: metadata,
                quality: .preserving(alpha: alpha != .none),
                evidence: .deterministicContract(fixtureID: fixtureID)
            )
        } catch {
            preconditionFailure("Static R12 fixture contract must be valid: \(error)")
        }
    }

    private static func sampling(
        storage: R12PixelStorageV2,
        bitDepth: R12BitDepthV2,
        subsampling: R12ChromaSubsamplingV2,
        range: R12CodeRangeV2,
        siting: R12ChromaSitingV2
    ) -> R12MediaSamplingV2 {
        do {
            return try R12MediaSamplingV2(
                storage: storage,
                bitDepth: bitDepth,
                chromaSubsampling: subsampling,
                codeRange: range,
                chromaSiting: siting
            )
        } catch {
            preconditionFailure("Static R12 sampling contract must be valid: \(error)")
        }
    }

    private static func hdrColor(
        _ transfer: R12TransferFunctionV2
    ) -> R12ColorContractV2 {
        do {
            return try .hdrBT2020(transferFunction: transfer)
        } catch {
            preconditionFailure("Static R12 HDR contract must be valid: \(error)")
        }
    }

    private static func scan(
        structure: R12ScanStructureV2,
        policy: R12DeinterlacePolicyV2
    ) -> R12ScanContractV2 {
        do {
            return try R12ScanContractV2(
                scanStructure: structure,
                deinterlacePolicy: policy
            )
        } catch {
            preconditionFailure("Static R12 scan contract must be valid: \(error)")
        }
    }
}

private enum R12CanonicalEncodingV2 {
    static func data<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            preconditionFailure("R12 canonical value failed to encode: \(error)")
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum R12ContractValidationV2 {
    static func identifier(_ value: String, field: String) throws -> String {
        let isAllowed = !value.isEmpty && value.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7a)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2d
                || byte == 0x2e
                || byte == 0x5f
        }
        guard isAllowed else {
            throw R12MediaFormatContractErrorV2.invalidIdentifier(
                field: field,
                value: value
            )
        }
        return value
    }

    static func sha256(_ value: String, field: String) throws -> String {
        let isLowercaseHex = value.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
        let isNonzero = value.contains { $0 != "0" }
        guard isLowercaseHex, isNonzero else {
            throw R12MediaFormatContractErrorV2.invalidSHA256(
                field: field,
                value: value
            )
        }
        return value
    }
}
