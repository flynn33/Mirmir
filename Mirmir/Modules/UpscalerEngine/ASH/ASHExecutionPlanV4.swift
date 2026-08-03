import Foundation

enum ASHExecutionPlanV4Error: Error, Equatable, Sendable {
    case unsupportedSchema(String)
    case noEnabledVideoTrack
    case duplicateTrackDirective(String)
    case missingTrackDirective(String)
    case directiveForDisabledOrUnknownTrack(String)
    case invalidDirective(trackID: String, reason: String)
    case unapprovedTrackDrop(String)
    case invalidUpscale(trackID: String)
    case invalidVerificationOrdering
    case invalidTrackPlanOrdering
    case runtimeIdentityMismatch
    case mediaIdentityMismatch
    case planIdentityMismatch(expected: ASHSHA256V4, actual: ASHSHA256V4)
}

enum ASHExecutorV4: String, Codable, Hashable, Sendable {
    case cpuFixedPoint = "cpu_fixed_point"
    case metalFixedPoint = "metal_fixed_point"
}

enum ASHReconstructionOutputRuleV4: String, Codable, Hashable, Sendable {
    /// Emit the exact integer blend produced by state-conditioned P06 operator
    /// expectations. An ordered candidate list is never an implicit output.
    case conditionedFixedPointBlend = "conditioned_fixed_point_blend"
}

enum ASHTrackActionV4: String, Codable, Hashable, Sendable {
    case processVideo = "process_video"
    case transcode
    case passThrough = "pass_through"
    case dropWithApproval = "drop_with_approval"
}

struct ASHVideoOutputContractV4: Codable, Equatable, Hashable, Sendable {
    let raster: CanonicalRasterV4
    let codecID: String
    let encodedFormatDescriptor: MediaTrackFormatDescriptorV4
    let pixelFormatID: String
    let bitDepth: UInt8
    let range: CanonicalPixelRangeV4
    let chromaSubsampling: CanonicalChromaSubsamplingV4
    let chromaSiting: CanonicalChromaSitingV4
    let alphaModel: CanonicalAlphaModelV4
    let color: CanonicalColorStateV4
}

struct ASHTrackDirectiveV4: Codable, Equatable, Hashable, Sendable {
    let trackID: String
    let action: ASHTrackActionV4
    let videoOutput: ASHVideoOutputContractV4?
    let outputCodecID: String?
    let dropReasonID: String?
    let dropApprovalSHA256: ASHSHA256V4?
}

struct ASHExecutionRequestV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaID = "ash.execution-request.v4.1"
    static let canonicalMeasurementContractID =
        ASHMeasurementContractV4.canonicalContractID
    static let canonicalKernelContractID =
        "ash-p06-catmull-rom-q14-largest-remainder-v1"

    let schemaID: String
    let executor: ASHExecutorV4
    let measurementContractID: String
    let kernelContractID: String
    let directives: [ASHTrackDirectiveV4]

    init(
        executor: ASHExecutorV4,
        measurementContractID: String,
        kernelContractID: String,
        directives: [ASHTrackDirectiveV4]
    ) {
        self.schemaID = Self.currentSchemaID
        self.executor = executor
        self.measurementContractID = measurementContractID
        self.kernelContractID = kernelContractID
        self.directives = directives
    }
}

struct ASHVideoScalePlanV4: Codable, Equatable, Hashable, Sendable {
    let sourceRaster: CanonicalRasterV4
    let targetRaster: CanonicalRasterV4
    let horizontalScale: ExactRationalV4
    let verticalScale: ExactRationalV4
}

struct ASHPlannedTrackV4: Codable, Equatable, Hashable, Sendable {
    let sourceIdentity: CanonicalTrackIdentityV4
    let kind: CanonicalMediaTrackKindV4
    let action: ASHTrackActionV4
    let sourceCodecID: String
    let outputCodecID: String?
    let videoOutput: ASHVideoOutputContractV4?
    let videoScale: ASHVideoScalePlanV4?
    let dropReasonID: String?
    let dropApprovalSHA256: ASHSHA256V4?
}

enum ASHVerificationRuleV4: String, Codable, CaseIterable, Comparable, Hashable,
    Sendable {
    case alphaIdentity = "alpha_identity"
    case attachmentSemantics = "attachment_semantics"
    case approvedDropRecord = "approved_drop_record"
    case colorSemantics = "color_semantics"
    case containerReadability = "container_readability"
    case duration = "duration"
    case encodedSampleIdentity = "encoded_sample_identity"
    case exactPresentationGeometry = "exact_presentation_geometry"
    case metadataSemantics = "metadata_semantics"
    case noUnplannedDrops = "no_unplanned_drops"
    case pixelLayout = "pixel_layout"
    case runtimeIdentity = "runtime_identity"
    case scanSemantics = "scan_semantics"
    case timingAndEditLists = "timing_and_edit_lists"
    case trackIdentityAndOrdering = "track_identity_and_ordering"
    case visiblePixelBytes = "visible_pixel_bytes"

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ASHVerificationRequirementV4: Codable, Comparable, Equatable, Hashable,
    Sendable {
    let trackID: String?
    let rule: ASHVerificationRuleV4

    static func < (lhs: Self, rhs: Self) -> Bool {
        let leftScope = lhs.trackID ?? ""
        let rightScope = rhs.trackID ?? ""
        if leftScope != rightScope { return leftScope < rightScope }
        return lhs.rule < rhs.rule
    }
}

struct ASHVerificationPlanV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaID = "ash.verification-plan.v4.1"

    let schemaID: String
    let requirements: [ASHVerificationRequirementV4]

    init(requirements: [ASHVerificationRequirementV4]) throws {
        self.schemaID = Self.currentSchemaID
        self.requirements = requirements
        try validate()
    }

    func validate() throws {
        guard schemaID == Self.currentSchemaID,
              requirements == Array(Set(requirements)).sorted() else {
            throw ASHExecutionPlanV4Error.invalidVerificationOrdering
        }
    }
}

struct ASHExecutionPlanV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaID = "ash.execution-plan.v4.2"
    static let identityDomain = "ash-execution-plan-v4"

    let schemaID: String
    let mediaStateSHA256: ASHSHA256V4
    let runtimeManifestSHA256: ASHSHA256V4
    let runtimeProvenanceSHA256: ASHSHA256V4
    let executor: ASHExecutorV4
    let reconstructionOutputRule: ASHReconstructionOutputRuleV4
    let measurementContractID: String
    let measurementContractSHA256: ASHSHA256V4
    let kernelContractID: String
    let branchAggregationSHA256: ASHSHA256V4
    let operatorBankSHA256: ASHSHA256V4
    let phaseCoefficientProcedureSHA256: ASHSHA256V4
    let tracks: [ASHPlannedTrackV4]
    let verification: ASHVerificationPlanV4

    fileprivate init(
        mediaStateSHA256: ASHSHA256V4,
        runtimeManifestSHA256: ASHSHA256V4,
        runtimeProvenanceSHA256: ASHSHA256V4,
        executor: ASHExecutorV4,
        measurementContractID: String,
        measurementContractSHA256: ASHSHA256V4,
        kernelContractID: String,
        branchAggregationSHA256: ASHSHA256V4,
        operatorBankSHA256: ASHSHA256V4,
        phaseCoefficientProcedureSHA256: ASHSHA256V4,
        tracks: [ASHPlannedTrackV4],
        verification: ASHVerificationPlanV4
    ) throws {
        self.schemaID = Self.currentSchemaID
        self.mediaStateSHA256 = mediaStateSHA256
        self.runtimeManifestSHA256 = runtimeManifestSHA256
        self.runtimeProvenanceSHA256 = runtimeProvenanceSHA256
        self.executor = executor
        self.reconstructionOutputRule = .conditionedFixedPointBlend
        self.measurementContractID = measurementContractID
        self.measurementContractSHA256 = measurementContractSHA256
        self.kernelContractID = kernelContractID
        self.branchAggregationSHA256 = branchAggregationSHA256
        self.operatorBankSHA256 = operatorBankSHA256
        self.phaseCoefficientProcedureSHA256 = phaseCoefficientProcedureSHA256
        self.tracks = tracks
        self.verification = verification
        try validate()
    }

    func validate() throws {
        guard schemaID == Self.currentSchemaID else {
            throw ASHExecutionPlanV4Error.unsupportedSchema(schemaID)
        }
        guard reconstructionOutputRule == .conditionedFixedPointBlend else {
            throw ASHExecutionPlanV4Error.runtimeIdentityMismatch
        }
        guard tracks == tracks.sorted(by: {
            $0.sourceIdentity < $1.sourceIdentity
        }), Set(tracks.map(\.sourceIdentity)).count == tracks.count else {
            throw ASHExecutionPlanV4Error.invalidTrackPlanOrdering
        }
        try verification.validate()
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
}

struct ASHIdentifiedExecutionPlanV4: Codable, Equatable, Hashable, Sendable {
    let plan: ASHExecutionPlanV4
    let planSHA256: ASHSHA256V4

    init(plan: ASHExecutionPlanV4) throws {
        self.plan = plan
        self.planSHA256 = try plan.canonicalSHA256
    }

    func verify() throws {
        try plan.validate()
        let actual = try plan.canonicalSHA256
        guard planSHA256 == actual else {
            throw ASHExecutionPlanV4Error.planIdentityMismatch(
                expected: planSHA256,
                actual: actual
            )
        }
    }
}

enum ASHExecutionPlannerV4 {
    static func makePlan(
        media: CanonicalMediaStateV4,
        request: ASHExecutionRequestV4,
        runtime: ASHVerifiedRuntimeBundleV4
    ) throws -> ASHIdentifiedExecutionPlanV4 {
        try media.validate()
        try runtime.verifyBinding()
        guard request.schemaID == ASHExecutionRequestV4.currentSchemaID else {
            throw ASHExecutionPlanV4Error.unsupportedSchema(request.schemaID)
        }

        let enabledTracks = media.tracks.filter(\.enabled)
        guard enabledTracks.contains(where: { $0.kind == .video }) else {
            throw ASHExecutionPlanV4Error.noEnabledVideoTrack
        }
        let enabledByID = Dictionary(
            uniqueKeysWithValues: enabledTracks.map {
                ($0.identity.persistentID, $0)
            }
        )
        var directivesByID: [String: ASHTrackDirectiveV4] = [:]
        for directive in request.directives {
            guard enabledByID[directive.trackID] != nil else {
                throw ASHExecutionPlanV4Error
                    .directiveForDisabledOrUnknownTrack(directive.trackID)
            }
            guard directivesByID.updateValue(
                directive,
                forKey: directive.trackID
            ) == nil else {
                throw ASHExecutionPlanV4Error.duplicateTrackDirective(
                    directive.trackID
                )
            }
        }

        var plannedTracks: [ASHPlannedTrackV4] = []
        plannedTracks.reserveCapacity(enabledTracks.count)
        for track in enabledTracks {
            let trackID = track.identity.persistentID
            guard let directive = directivesByID[trackID] else {
                throw ASHExecutionPlanV4Error.missingTrackDirective(trackID)
            }
            plannedTracks.append(
                try plan(track: track, directive: directive)
            )
        }

        let manifest = runtime.manifest
        let measurementArtifact = manifest.artifact(for: .measurementContract)
        let branchArtifact = manifest.artifact(for: .branchAggregation)
        let operatorArtifact = manifest.artifact(for: .operatorBank)
        let phaseArtifact = manifest.artifact(for: .phaseCoefficientProcedure)
        guard request.measurementContractID
                == ASHExecutionRequestV4.canonicalMeasurementContractID,
              request.kernelContractID
                == ASHExecutionRequestV4.canonicalKernelContractID else {
            throw ASHExecutionPlanV4Error.runtimeIdentityMismatch
        }

        let verification = try makeVerificationPlan(tracks: plannedTracks)
        let plan = try ASHExecutionPlanV4(
            mediaStateSHA256: media.canonicalSHA256,
            runtimeManifestSHA256: runtime.manifestSHA256,
            runtimeProvenanceSHA256: try manifest.provenance.canonicalSHA256,
            executor: request.executor,
            measurementContractID: request.measurementContractID,
            measurementContractSHA256: measurementArtifact.contentSHA256,
            kernelContractID: request.kernelContractID,
            branchAggregationSHA256: branchArtifact.contentSHA256,
            operatorBankSHA256: operatorArtifact.contentSHA256,
            phaseCoefficientProcedureSHA256: phaseArtifact.contentSHA256,
            tracks: plannedTracks,
            verification: verification
        )
        return try ASHIdentifiedExecutionPlanV4(plan: plan)
    }

    private static func plan(
        track: CanonicalMediaTrackV4,
        directive: ASHTrackDirectiveV4
    ) throws -> ASHPlannedTrackV4 {
        let trackID = track.identity.persistentID
        switch directive.action {
        case .processVideo:
            guard let sourceVideo = track.video,
                  let output = directive.videoOutput,
                  directive.outputCodecID == nil,
                  directive.dropReasonID == nil,
                  directive.dropApprovalSHA256 == nil else {
                throw ASHExecutionPlanV4Error.invalidDirective(
                    trackID: trackID,
                    reason: "process_video requires only a video output contract"
                )
            }
            guard output.raster.width >= sourceVideo.encodedRaster.width,
                  output.raster.height >= sourceVideo.encodedRaster.height,
                  output.raster.width > sourceVideo.encodedRaster.width
                    || output.raster.height > sourceVideo.encodedRaster.height,
                  output.raster.width > 0,
                  output.raster.height > 0,
                  (1...16).contains(output.bitDepth) else {
                throw ASHExecutionPlanV4Error.invalidUpscale(trackID: trackID)
            }
            guard output.encodedFormatDescriptor.completeness == .complete,
                  output.encodedFormatDescriptor.mediaTypeID
                    == "fourcc_76696465",
                  output.encodedFormatDescriptor.videoRaster == output.raster,
                  output.encodedFormatDescriptor.mediaSubtypeID
                    == encodedMediaSubtypeID(for: output.codecID) else {
                throw ASHExecutionPlanV4Error.invalidDirective(
                    trackID: trackID,
                    reason: "encoded format descriptor disagrees with codec or raster"
                )
            }
            let horizontal = try ExactRationalV4(
                output.raster.width,
                sourceVideo.encodedRaster.width
            )
            let vertical = try ExactRationalV4(
                output.raster.height,
                sourceVideo.encodedRaster.height
            )
            return ASHPlannedTrackV4(
                sourceIdentity: track.identity,
                kind: track.kind,
                action: directive.action,
                sourceCodecID: track.codecID,
                outputCodecID: output.codecID,
                videoOutput: output,
                videoScale: ASHVideoScalePlanV4(
                    sourceRaster: sourceVideo.encodedRaster,
                    targetRaster: output.raster,
                    horizontalScale: horizontal,
                    verticalScale: vertical
                ),
                dropReasonID: nil,
                dropApprovalSHA256: nil
            )
        case .transcode:
            guard directive.videoOutput == nil,
                  let outputCodecID = directive.outputCodecID,
                  !outputCodecID.isEmpty,
                  directive.dropReasonID == nil,
                  directive.dropApprovalSHA256 == nil else {
                throw ASHExecutionPlanV4Error.invalidDirective(
                    trackID: trackID,
                    reason: "transcode requires exactly one output codec"
                )
            }
            return ASHPlannedTrackV4(
                sourceIdentity: track.identity,
                kind: track.kind,
                action: directive.action,
                sourceCodecID: track.codecID,
                outputCodecID: outputCodecID,
                videoOutput: nil,
                videoScale: nil,
                dropReasonID: nil,
                dropApprovalSHA256: nil
            )
        case .passThrough:
            guard directive.videoOutput == nil,
                  directive.outputCodecID == nil,
                  directive.dropReasonID == nil,
                  directive.dropApprovalSHA256 == nil else {
                throw ASHExecutionPlanV4Error.invalidDirective(
                    trackID: trackID,
                    reason: "pass_through accepts no output or drop values"
                )
            }
            return ASHPlannedTrackV4(
                sourceIdentity: track.identity,
                kind: track.kind,
                action: directive.action,
                sourceCodecID: track.codecID,
                outputCodecID: track.codecID,
                videoOutput: nil,
                videoScale: nil,
                dropReasonID: nil,
                dropApprovalSHA256: nil
            )
        case .dropWithApproval:
            guard directive.videoOutput == nil,
                  directive.outputCodecID == nil,
                  let reason = directive.dropReasonID,
                  !reason.isEmpty,
                  let approval = directive.dropApprovalSHA256 else {
                throw ASHExecutionPlanV4Error.unapprovedTrackDrop(trackID)
            }
            return ASHPlannedTrackV4(
                sourceIdentity: track.identity,
                kind: track.kind,
                action: directive.action,
                sourceCodecID: track.codecID,
                outputCodecID: nil,
                videoOutput: nil,
                videoScale: nil,
                dropReasonID: reason,
                dropApprovalSHA256: approval
            )
        }
    }

    private static func makeVerificationPlan(
        tracks: [ASHPlannedTrackV4]
    ) throws -> ASHVerificationPlanV4 {
        var requirements = Set<ASHVerificationRequirementV4>()
        for rule in [
            ASHVerificationRuleV4.containerReadability,
            .duration,
            .noUnplannedDrops,
            .runtimeIdentity,
            .trackIdentityAndOrdering
        ] {
            requirements.insert(
                ASHVerificationRequirementV4(trackID: nil, rule: rule)
            )
        }
        for track in tracks {
            let trackID = track.sourceIdentity.persistentID
            let rules: [ASHVerificationRuleV4]
            switch track.action {
            case .processVideo:
                var videoRules: [ASHVerificationRuleV4] = [
                    .attachmentSemantics,
                    .colorSemantics,
                    .exactPresentationGeometry,
                    .metadataSemantics,
                    .pixelLayout,
                    .scanSemantics,
                    .timingAndEditLists,
                    .visiblePixelBytes
                ]
                if track.videoOutput?.alphaModel != CanonicalAlphaModelV4.none {
                    videoRules.append(.alphaIdentity)
                }
                rules = videoRules
            case .transcode:
                rules = [
                    .metadataSemantics,
                    .timingAndEditLists,
                    .trackIdentityAndOrdering
                ]
            case .passThrough:
                rules = [
                    .encodedSampleIdentity,
                    .metadataSemantics,
                    .timingAndEditLists
                ]
            case .dropWithApproval:
                rules = [.approvedDropRecord]
            }
            for rule in rules {
                requirements.insert(
                    ASHVerificationRequirementV4(trackID: trackID, rule: rule)
                )
            }
        }
        return try ASHVerificationPlanV4(requirements: requirements.sorted())
    }

    private static func encodedMediaSubtypeID(for codecID: String) -> String? {
        switch codecID {
        case "h264": "fourcc_61766331"
        case "hevc": "fourcc_68766331"
        case "proRes422": "fourcc_6170636e"
        case "proRes4444": "fourcc_61703468"
        default: nil
        }
    }
}
