import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

enum DeterministicV4WholeAssetPlannerError: Error, Equatable, Sendable {
    case deterministicPlanningBackendRequired
    case primaryVideoMissing
    case canonicalAndTrackGraphInventoriesDiffer
    case canonicalAndTrackGraphKindsDiffer(ordinal: UInt32)
    case unsupportedOutputCodec(OutputCodec)
    case alphaSourceRequiresProRes4444(OutputCodec)
    case proRes4444RequiresAlphaSource
    case preparedAlphaConfigurationMismatch
    case unsupportedAlphaAssociation(CanonicalAlphaModelV4)
    case unsupportedSourcePixelContract(String)
    case unsupportedSourceColorContract(String)
    case invalidHDRStaticMetadata(String)
    case migrationBlueprintContainsIncompatibility
    case ashAndTrackPlansDisagree(ordinal: UInt32)
    case invalidNominalFrameDuration
}

enum DeterministicV4VideoDeliveryPlan: Sendable {
    case opaque(VideoWriterFormatContractV4)
    case alpha(PreparedAlphaVideoDeliveryV4)
}

/// All policy and encoder facts needed to execute one deterministic whole-
/// asset migration. Construction performs the real encoder calibration and
/// creates both immutable plans before a source sample is decoded.
struct DeterministicV4PreparedAssetPlan: Sendable {
    let canonicalMedia: CanonicalMediaStateV4
    let ashPlan: ASHIdentifiedExecutionPlanV4
    let sourceGraph: MediaTrackGraphV4
    let trackPlan: MediaTrackGraphIdentifiedPlanV4
    let migrationBlueprint: AVFoundationTrackMigrationBlueprintV4
    let primaryCanonicalTrack: CanonicalMediaTrackV4
    let primaryGraphTrack: MediaTrackNodeV4
    let videoDelivery: DeterministicV4VideoDeliveryPlan
    let encodedFormatDescriptor: MediaTrackFormatDescriptorV4
    let nominalSourceFrameDuration: ExactRationalV4

    func makeProcessingHook(
        backend: any PreparedFrameUpscaler,
        startingFrameIndex: Int = 0,
        finishBackendAtEnd: Bool = true,
        recordAlphaForFinalVerification: Bool = true
    ) throws -> AVFoundationVideoTrackProcessingHookV4 {
        switch videoDelivery {
        case .opaque(let writerContract):
            return try PreparedFrameUpscalerTrackHookV4.make(
                trackID: primaryGraphTrack.identity.stableID,
                preparedBackend: backend,
                writerOutputSettings: writerContract.outputSettings,
                declaredOutputFormats: [encodedFormatDescriptor],
                nominalSourceFrameDuration: nominalSourceFrameDuration,
                outputPreferredTransform:
                    writerContract.geometry.avPreferredTransform,
                outputNaturalSize: CGSize(
                    width: writerContract.geometry.codedWidth,
                    height: writerContract.geometry.codedHeight
                ),
                startingFrameIndex: startingFrameIndex,
                finishBackendAtEnd: finishBackendAtEnd
            )
        case .alpha(let delivery):
            return try delivery.makeProcessingHook(
                trackID: primaryGraphTrack.identity.stableID,
                nominalSourceFrameDuration: nominalSourceFrameDuration,
                outputPreferredTransform:
                    delivery.writerContract.geometry.avPreferredTransform,
                outputNaturalSize: CGSize(
                    width: delivery.writerContract.geometry.codedWidth,
                    height: delivery.writerContract.geometry.codedHeight
                ),
                startingFrameIndex: startingFrameIndex,
                finishBackendAtEnd: finishBackendAtEnd,
                recordForFinalVerification: recordAlphaForFinalVerification
            )
        }
    }

    func verifyProcessedOutput(at url: URL) async throws {
        guard case .alpha(let delivery) = videoDelivery else { return }
        let videoTracks = sourceGraph.tracks.filter { $0.kind == .video }
        guard let ordinal = videoTracks.firstIndex(where: {
            $0.identity.stableID == primaryGraphTrack.identity.stableID
        }) else {
            throw DeterministicV4WholeAssetPlannerError.primaryVideoMissing
        }
        _ = try await delivery.verifyMigratedOutput(
            at: url,
            videoTrackOrdinal: ordinal
        )
    }

    func checkpointableProcessingBackend(
        planningBackend: any PreparedDeterministicV4RuntimePlanningBackend
    ) throws -> any PreparedCheckpointableTemporalFrameUpscaler {
        switch videoDelivery {
        case .opaque:
            guard let checkpointable = planningBackend
                as? any PreparedCheckpointableTemporalFrameUpscaler else {
                throw DeterministicV4WholeAssetPlannerError
                    .deterministicPlanningBackendRequired
            }
            return checkpointable
        case .alpha(let delivery):
            return delivery.backend
        }
    }

    func finishProcessingBackend(
        planningBackend: any PreparedDeterministicV4RuntimePlanningBackend
    ) async {
        if case .alpha(let delivery) = videoDelivery {
            try? await delivery.backend.finish()
        }
        try? await planningBackend.finish()
    }
}

actor DeterministicV4WholeAssetPlanner {
    private static let audioOmissionReasonID =
        "user_requested_audio_omission_v4"
    private static let ephemeralBookmarkReference =
        "ephemeral-current-session-v4"

    private let canonicalAdapter: AVCanonicalMediaStateAdapterV4
    private let formatCalibrator: AVFoundationVideoFormatCalibratorV4
    private let alphaDeliveryPlanner: DeterministicAlphaVideoDeliveryPlannerV4

    init(
        canonicalAdapter: AVCanonicalMediaStateAdapterV4 = .init(),
        formatCalibrator: AVFoundationVideoFormatCalibratorV4 = .init(),
        alphaDeliveryPlanner: DeterministicAlphaVideoDeliveryPlannerV4 = .init()
    ) {
        self.canonicalAdapter = canonicalAdapter
        self.formatCalibrator = formatCalibrator
        self.alphaDeliveryPlanner = alphaDeliveryPlanner
    }

    func prepare(
        request: UpscaleRequest,
        source: VideoInfo,
        backend: any PreparedDeterministicV4RuntimePlanningBackend
    ) async throws -> DeterministicV4PreparedAssetPlan {
        let bookmarkDocumentSHA256 = ASHSHA256V4(rawData: Data(
            (Self.ephemeralBookmarkReference + "|v1").utf8
        ))
        let canonicalProbe = try await canonicalAdapter.probe(.init(
            url: request.inputURL,
            bookmarkReference: Self.ephemeralBookmarkReference,
            bookmarkDocumentSHA256: bookmarkDocumentSHA256,
            scanDynamicHDRMetadata: true
        ))
        let canonicalMedia = try canonicalProbe.requireAdmittedState()
        let asset = AVURLAsset(
            url: request.inputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let graph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: asset
        )
        let pairings = try reconcile(canonicalMedia: canonicalMedia, graph: graph)
        guard let primaryPair = pairings.first(where: {
            $0.canonical.enabled && $0.canonical.kind == .video
        }) else {
            throw DeterministicV4WholeAssetPlannerError.primaryVideoMissing
        }
        guard let sourceVideo = primaryPair.canonical.video else {
            throw DeterministicV4WholeAssetPlannerError.primaryVideoMissing
        }

        let videoDelivery = try await prepareVideoDelivery(
            request: request,
            video: sourceVideo,
            backend: backend,
            outputFrameCount: (backend as? any PreparedTemporalFrameUpscaler)?
                .maximumOutputFramesPerInput ?? 1
        )
        let encodedDescriptor: MediaTrackFormatDescriptorV4
        switch videoDelivery {
        case .opaque(let contract):
            encodedDescriptor = try await formatCalibrator.formatDescriptor(
                for: contract
            )
        case .alpha(let delivery):
            encodedDescriptor = delivery.encodedFormatDescriptor
        }
        let approvalSHA256 = audioOmissionApproval(
            input: canonicalMedia.input,
            request: request
        )
        let ashRequest = try makeASHRequest(
            canonicalMedia: canonicalMedia,
            primaryOrdinal: primaryPair.canonical.identity.ordinal,
            request: request,
            backend: backend,
            videoDelivery: videoDelivery,
            encodedDescriptor: encodedDescriptor,
            approvalSHA256: approvalSHA256
        )
        let ashPlan = try await backend.makeASHExecutionPlan(
            media: canonicalMedia,
            request: ashRequest
        )
        try ashPlan.verify()

        let graphRequest = try makeGraphRequest(
            graph: graph,
            primaryTrackID: primaryPair.graph.identity.stableID,
            encodedDescriptor: encodedDescriptor,
            preserveAudio: request.preserveAudio,
            approvalSHA256: approvalSHA256
        )
        let trackPlan = try MediaTrackGraphPlannerV4.makePlan(
            source: graph,
            request: graphRequest
        )
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: graph,
            plan: trackPlan
        )
        guard !blueprint.hasIncompatibility else {
            throw DeterministicV4WholeAssetPlannerError
                .migrationBlueprintContainsIncompatibility
        }
        try verifyPlanAgreement(
            pairings: pairings,
            canonicalMedia: canonicalMedia,
            ashPlan: ashPlan,
            trackPlan: trackPlan
        )

        return DeterministicV4PreparedAssetPlan(
            canonicalMedia: canonicalMedia,
            ashPlan: ashPlan,
            sourceGraph: graph,
            trackPlan: trackPlan,
            migrationBlueprint: blueprint,
            primaryCanonicalTrack: primaryPair.canonical,
            primaryGraphTrack: primaryPair.graph,
            videoDelivery: videoDelivery,
            encodedFormatDescriptor: encodedDescriptor,
            nominalSourceFrameDuration: try nominalFrameDuration(
                source: source,
                track: primaryPair.graph
            )
        )
    }

    /// Granular production planning surface used by qualification tests and
    /// by the whole-asset plan. Keeping both callers on this path prevents
    /// media-policy tests from silently diverging from asset preparation.
    func prepareVideoDelivery(
        request: UpscaleRequest,
        video: CanonicalVideoStateV4,
        backend: any PreparedDeterministicV4RuntimePlanningBackend,
        outputFrameCount: Int
    ) async throws -> DeterministicV4VideoDeliveryPlan {
        try await makeVideoDelivery(
            request: request,
            video: video,
            backend: backend,
            outputFrameCount: outputFrameCount
        )
    }
}

private extension DeterministicV4WholeAssetPlanner {
    struct TrackPair {
        let canonical: CanonicalMediaTrackV4
        let graph: MediaTrackNodeV4
    }

    func reconcile(
        canonicalMedia: CanonicalMediaStateV4,
        graph: MediaTrackGraphV4
    ) throws -> [TrackPair] {
        let physicalCanonical = canonicalMedia.tracks.filter {
            Int($0.identity.ordinal) < graph.tracks.count
        }
        guard physicalCanonical.count == graph.tracks.count else {
            throw DeterministicV4WholeAssetPlannerError
                .canonicalAndTrackGraphInventoriesDiffer
        }
        return try zip(physicalCanonical, graph.tracks).map { canonical, node in
            guard canonical.identity.ordinal == node.identity.ordinal else {
                throw DeterministicV4WholeAssetPlannerError
                    .canonicalAndTrackGraphInventoriesDiffer
            }
            guard canonical.kind.graphKind == node.kind else {
                throw DeterministicV4WholeAssetPlannerError
                    .canonicalAndTrackGraphKindsDiffer(
                        ordinal: canonical.identity.ordinal
                    )
            }
            return TrackPair(canonical: canonical, graph: node)
        }
    }

    func makeASHRequest(
        canonicalMedia: CanonicalMediaStateV4,
        primaryOrdinal: UInt32,
        request: UpscaleRequest,
        backend: any PreparedDeterministicV4RuntimePlanningBackend,
        videoDelivery: DeterministicV4VideoDeliveryPlan,
        encodedDescriptor: MediaTrackFormatDescriptorV4,
        approvalSHA256: ASHSHA256V4
    ) throws -> ASHExecutionRequestV4 {
        let directives = try canonicalMedia.tracks
            .filter(\.enabled)
            .map { track -> ASHTrackDirectiveV4 in
                if track.identity.ordinal == primaryOrdinal {
                    guard let video = track.video else {
                        throw DeterministicV4WholeAssetPlannerError
                            .primaryVideoMissing
                    }
                    return ASHTrackDirectiveV4(
                        trackID: track.identity.persistentID,
                        action: .processVideo,
                        videoOutput: try videoOutputContract(
                            source: video,
                            request: request,
                            videoDelivery: videoDelivery,
                            encodedDescriptor: encodedDescriptor
                        ),
                        outputCodecID: nil,
                        dropReasonID: nil,
                        dropApprovalSHA256: nil
                    )
                }
                if track.kind == .audio, !request.preserveAudio {
                    return ASHTrackDirectiveV4(
                        trackID: track.identity.persistentID,
                        action: .dropWithApproval,
                        videoOutput: nil,
                        outputCodecID: nil,
                        dropReasonID: Self.audioOmissionReasonID,
                        dropApprovalSHA256: approvalSHA256
                    )
                }
                return ASHTrackDirectiveV4(
                    trackID: track.identity.persistentID,
                    action: .passThrough,
                    videoOutput: nil,
                    outputCodecID: nil,
                    dropReasonID: nil,
                    dropApprovalSHA256: nil
                )
            }
        return ASHExecutionRequestV4(
            executor: backend.deterministicExecutor,
            measurementContractID:
                ASHExecutionRequestV4.canonicalMeasurementContractID,
            kernelContractID:
                ASHExecutionRequestV4.canonicalKernelContractID,
            directives: directives
        )
    }

    func makeGraphRequest(
        graph: MediaTrackGraphV4,
        primaryTrackID: MediaTrackStableIDV4,
        encodedDescriptor: MediaTrackFormatDescriptorV4,
        preserveAudio: Bool,
        approvalSHA256: ASHSHA256V4
    ) throws -> MediaTrackGraphPlanningRequestV4 {
        var consents: [MediaTrackStableIDV4: MediaTrackDropConsentV4] = [:]
        let trackDirectives = try graph.tracks.map { track in
            if track.identity.stableID == primaryTrackID {
                return MediaTrackDirectiveV4(
                    trackID: track.identity.stableID,
                    action: .process,
                    targetFormatDescriptors: [encodedDescriptor],
                    dropConsent: nil
                )
            }
            if track.kind == .audio, !preserveAudio {
                let consent = try MediaTrackDropConsentV4(
                    subjectID: track.identity.stableID.rawValue,
                    reasonID: Self.audioOmissionReasonID,
                    approvalSHA256: approvalSHA256
                )
                consents[track.identity.stableID] = consent
                return MediaTrackDirectiveV4(
                    trackID: track.identity.stableID,
                    action: .dropWithConsent,
                    targetFormatDescriptors: [],
                    dropConsent: consent
                )
            }
            return MediaTrackDirectiveV4(
                trackID: track.identity.stableID,
                action: .passThrough,
                targetFormatDescriptors: [],
                dropConsent: nil
            )
        }
        let groupDirectives: [MediaTrackGroupDirectiveV4] = try graph.groups
            .compactMap { group -> MediaTrackGroupDirectiveV4? in
            let survivors = group.memberTrackIDs.filter { consents[$0] == nil }
            guard survivors.count != group.memberTrackIDs.count else {
                return nil
            }
            let consent = try MediaTrackDropConsentV4(
                subjectID: group.identity.stableID.rawValue,
                reasonID: Self.audioOmissionReasonID,
                approvalSHA256: approvalSHA256
            )
            if survivors.isEmpty {
                return MediaTrackGroupDirectiveV4(
                    groupID: group.identity.stableID,
                    action: .dropWithConsent,
                    outputMemberTrackIDs: nil,
                    outputDefaultTrackID: nil,
                    dropConsent: consent
                )
            }
            return MediaTrackGroupDirectiveV4(
                groupID: group.identity.stableID,
                action: .transcode,
                outputMemberTrackIDs: survivors,
                outputDefaultTrackID: group.defaultTrackID.flatMap {
                    survivors.contains($0) ? $0 : survivors.first
                },
                dropConsent: consent
            )
        }
        return MediaTrackGraphPlanningRequestV4(
            trackDirectives: trackDirectives,
            groupDirectives: groupDirectives
        )
    }

    func makeVideoDelivery(
        request: UpscaleRequest,
        video: CanonicalVideoStateV4,
        backend: any PreparedDeterministicV4RuntimePlanningBackend,
        outputFrameCount: Int
    ) async throws -> DeterministicV4VideoDeliveryPlan {
        guard video.pixel.alphaModel != .unknown else {
            throw DeterministicV4WholeAssetPlannerError
                .unsupportedAlphaAssociation(.unknown)
        }
        if video.pixel.alphaModel == .none {
            guard request.outputCodec != .proRes4444 else {
                throw DeterministicV4WholeAssetPlannerError
                    .proRes4444RequiresAlphaSource
            }
            guard let opaque = backend
                as? any PreparedDeterministicV4PlanningBackend else {
                throw DeterministicV4WholeAssetPlannerError
                    .deterministicPlanningBackendRequired
            }
            return .opaque(try makeWriterContract(
                request: request,
                video: video,
                storage: opaque.deterministicStorage,
                outputFrameCount: outputFrameCount
            ))
        }

        guard request.outputCodec == .proRes4444 else {
            throw DeterministicV4WholeAssetPlannerError
                .alphaSourceRequiresProRes4444(request.outputCodec)
        }
        guard video.scan.fieldCount == 1,
              video.scan.dominance == .none,
              video.scan.cadence == .progressive else {
            throw DeterministicV4WholeAssetPlannerError
                .unsupportedSourcePixelContract(
                    "packed-alpha field normalization requires a temporal contract"
                )
        }
        guard let sourceWidth = Int(exactly: video.encodedRaster.width),
              let sourceHeight = Int(exactly: video.encodedRaster.height) else {
            throw DeterministicV4WholeAssetPlannerError
                .unsupportedSourcePixelContract(video.pixel.formatID)
        }
        let association: AlphaAssociationV4
        let zeroAlphaPolicy: ZeroAlphaPolicyV4
        switch video.pixel.alphaModel {
        case .straight:
            association = .straight
            zeroAlphaPolicy = .preserveStraightColor
        case .premultiplied:
            association = .premultiplied
            zeroAlphaPolicy = .rejectNonZeroColor
        case .none, .unknown:
            throw DeterministicV4WholeAssetPlannerError
                .unsupportedAlphaAssociation(video.pixel.alphaModel)
        }
        guard video.color.masteringDisplay == nil,
              video.color.contentLightLevel == nil,
              video.color.dynamicHDRMetadata.isEmpty else {
            throw DeterministicV4WholeAssetPlannerError
                .unsupportedSourceColorContract(
                    "alpha HDR metadata requires a dedicated ProRes 4444 policy"
                )
        }
        let layout: Alpha4444PackedLayoutV4 = video.pixel.bitDepth <= 8
            ? .bgra8
            : .argb16BigEndian
        let scalePlan = try Alpha4444ScalePlanV4(
            layout: layout,
            sourceAssociation: association,
            destinationAssociation: association,
            zeroAlphaPolicy: zeroAlphaPolicy,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: request.targetWidth,
            targetHeight: request.targetHeight,
            borderRule: .reflect101
        )
        guard let alphaBackend = backend
            as? any PreparedDeterministicAlphaRuntimePlanningBackendV4,
              alphaBackend.alphaConfiguration.layout == layout,
              alphaBackend.alphaConfiguration.association == association,
              alphaBackend.alphaConfiguration.sourceWidth == sourceWidth,
              alphaBackend.alphaConfiguration.sourceHeight == sourceHeight,
              alphaBackend.alphaConfiguration.targetWidth
                == request.targetWidth,
              alphaBackend.alphaConfiguration.targetHeight
                == request.targetHeight else {
            throw DeterministicV4WholeAssetPlannerError
                .preparedAlphaConfigurationMismatch
        }
        let executionContext = try await alphaBackend
            .makeAlphaExecutionContext()
        return .alpha(try await alphaDeliveryPlanner.prepare(
            scalePlan: scalePlan,
            executionContext: executionContext,
            codec: .proRes4444,
            sourceGeometry: try sourceGeometry(video),
            color: AlphaVideoColorPropertiesV4(
                primaries: video.color.primaries,
                transferFunction: video.color.transferFunction,
                matrix: video.color.matrix
            )
        ))
    }

    func makeWriterContract(
        request: UpscaleRequest,
        video: CanonicalVideoStateV4,
        storage: PixelStorageV4,
        outputFrameCount: Int
    ) throws -> VideoWriterFormatContractV4 {
        let codec: VideoWriterCodecV4
        switch request.outputCodec {
        case .h264: codec = .h264
        case .hevc: codec = .hevc
        case .proRes422:
            throw DeterministicV4WholeAssetPlannerError
                .unsupportedOutputCodec(.proRes422)
        case .proRes4444:
            throw DeterministicV4WholeAssetPlannerError
                .proRes4444RequiresAlphaSource
        }
        try validate(pixel: video.pixel, storage: storage)
        let geometry = try sourceGeometry(video)
        let color = try writerColor(video.color, storage: storage)
        let containsDynamicHDR = !video.color.dynamicHDRMetadata.isEmpty
        return try VideoWriterFormatContractV4(
            codec: codec,
            storage: storage,
            color: color,
            sourceGeometry: geometry,
            outputWidth: request.targetWidth,
            outputHeight: request.targetHeight,
            frameOperation: outputFrameCount > 1
                ? .fieldNormalization
                : .spatialResampling,
            sourceContainsDynamicHDRMetadata: containsDynamicHDR,
            dynamicEncodingPolicy: !containsDynamicHDR
                ? .absent
                : outputFrameCount > 1
                    ? .replicateSourceSceneMetadataAcrossFieldNormalization
                    : .preserveSourceSceneMetadataAcrossSpatialResampling
        )
    }

    func validate(
        pixel: CanonicalPixelStateV4,
        storage: PixelStorageV4
    ) throws {
        let range: CanonicalPixelRangeV4 = storage.codeRange == .video
            ? .video
            : .full
        guard pixel.bitDepth == storage.signalBitDepth,
              pixel.range == range,
              pixel.chromaSubsampling == .yuv420,
              pixel.alphaModel == .none else {
            throw DeterministicV4WholeAssetPlannerError
                .unsupportedSourcePixelContract(pixel.formatID)
        }
    }

    func sourceGeometry(
        _ video: CanonicalVideoStateV4
    ) throws -> RationalPresentationGeometryV4 {
        let width = video.encodedRaster.width
        let height = video.encodedRaster.height
        let clean: CleanApertureV4
        if let rect = video.cleanAperture {
            let two = try ExactRationalV4(2)
            let xMargin = try ExactRationalV4(width)
                .subtracting(rect.size.width)
                .divided(by: two)
            let yMargin = try ExactRationalV4(height)
                .subtracting(rect.size.height)
                .divided(by: two)
            clean = try CleanApertureV4(
                width: rect.size.width,
                height: rect.size.height,
                horizontalOffset: try rect.origin.x.subtracting(xMargin),
                verticalOffset: try rect.origin.y.subtracting(yMargin)
            )
        } else {
            clean = try .fullRaster(width: width, height: height)
        }
        return try RationalPresentationGeometryV4(
            codedWidth: width,
            codedHeight: height,
            cleanAperture: clean,
            sampleAspectRatio: try SampleAspectRatioV4(
                horizontalSpacing: video.pixelAspectRatio.numerator,
                verticalSpacing: video.pixelAspectRatio.denominator
            ),
            preferredTransform: RationalAffineTransformV4(
                a: video.preferredTransform.a,
                b: video.preferredTransform.b,
                c: video.preferredTransform.c,
                d: video.preferredTransform.d,
                tx: video.preferredTransform.tx,
                ty: video.preferredTransform.ty
            )
        )
    }

    func writerColor(
        _ color: CanonicalColorStateV4,
        storage: PixelStorageV4
    ) throws -> VideoWriterColorContractV4 {
        let bt709 = kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String
        let transfer709 =
            kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String
        let matrix709 = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String
        if color.transferFunction == transfer709 {
            guard color.primaries == bt709,
                  color.matrix == matrix709,
                  color.masteringDisplay == nil,
                  color.contentLightLevel == nil,
                  color.dynamicHDRMetadata.isEmpty else {
                throw DeterministicV4WholeAssetPlannerError
                    .unsupportedSourceColorContract(color.transferFunction)
            }
            return .sdrBT709
        }

        let transfer: HDRTransferFunctionV4
        if color.transferFunction
            == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String {
            transfer = .pq
        } else if color.transferFunction
            == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String {
            transfer = .hlg
        } else {
            throw DeterministicV4WholeAssetPlannerError
                .unsupportedSourceColorContract(color.transferFunction)
        }
        guard color.primaries
                == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String,
              color.matrix
                == kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String else {
            throw DeterministicV4WholeAssetPlannerError
                .unsupportedSourceColorContract(color.transferFunction)
        }
        let mastering = try color.masteringDisplay.map(makeMasteringDisplay)
        let contentLight = try color.contentLightLevel.map(makeContentLight)
        return .hdr(HDRFormatMetadataV4(
            signal: try HDRSignalV4(
                storage: storage,
                transferFunction: transfer
            ),
            staticMetadata: HDRStaticMetadataV4(
                masteringDisplayColorVolume: mastering,
                contentLightLevelInfo: contentLight
            )
        ))
    }

    func makeMasteringDisplay(
        _ source: CanonicalMasteringDisplayV4
    ) throws -> MasteringDisplayColorVolumeV4 {
        guard source.displayPrimariesX.count == 3,
              source.displayPrimariesY.count == 3 else {
            throw DeterministicV4WholeAssetPlannerError
                .invalidHDRStaticMetadata("mastering_primaries")
        }
        let primaries = try zip(
            source.displayPrimariesX,
            source.displayPrimariesY
        ).enumerated().map { index, values in
            try HDRChromaticityV4(
                x: scaledUInt16(values.0, by: 50_000),
                y: scaledUInt16(values.1, by: 50_000),
                label: "display_primary_\(index)"
            )
        }
        return try MasteringDisplayColorVolumeV4(
            displayPrimaries: primaries,
            whitePoint: HDRChromaticityV4(
                x: scaledUInt16(source.whitePointX, by: 50_000),
                y: scaledUInt16(source.whitePointY, by: 50_000),
                label: "white_point"
            ),
            maximumDisplayMasteringLuminance:
                scaledUInt32(source.maximumLuminance, by: 10_000),
            minimumDisplayMasteringLuminance:
                scaledUInt32(source.minimumLuminance, by: 10_000)
        )
    }

    func makeContentLight(
        _ source: CanonicalContentLightLevelV4
    ) throws -> ContentLightLevelInfoV4 {
        guard source.maximumContentLightLevel <= UInt16.max,
              source.maximumFrameAverageLightLevel <= UInt16.max else {
            throw DeterministicV4WholeAssetPlannerError
                .invalidHDRStaticMetadata("content_light")
        }
        return try ContentLightLevelInfoV4(
            maximumContentLightLevel: UInt16(source.maximumContentLightLevel),
            maximumFrameAverageLightLevel:
                UInt16(source.maximumFrameAverageLightLevel)
        )
    }

    func scaledUInt16(
        _ value: ExactRationalV4,
        by scale: Int64
    ) throws -> UInt16 {
        let scaled = try value.multiplied(by: ExactRationalV4(scale))
        guard let integer = scaled.integerValue,
              integer >= 0,
              integer <= UInt16.max else {
            throw DeterministicV4WholeAssetPlannerError
                .invalidHDRStaticMetadata("uint16")
        }
        return UInt16(integer)
    }

    func scaledUInt32(
        _ value: ExactRationalV4,
        by scale: Int64
    ) throws -> UInt32 {
        let scaled = try value.multiplied(by: ExactRationalV4(scale))
        guard let integer = scaled.integerValue,
              integer >= 0,
              integer <= UInt32.max else {
            throw DeterministicV4WholeAssetPlannerError
                .invalidHDRStaticMetadata("uint32")
        }
        return UInt32(integer)
    }

    func videoOutputContract(
        source: CanonicalVideoStateV4,
        request: UpscaleRequest,
        videoDelivery: DeterministicV4VideoDeliveryPlan,
        encodedDescriptor: MediaTrackFormatDescriptorV4
    ) throws -> ASHVideoOutputContractV4 {
        let raster = CanonicalRasterV4(
            width: Int64(request.targetWidth),
            height: Int64(request.targetHeight)
        )
        switch videoDelivery {
        case .alpha(let delivery):
            let layout = delivery.writerContract.inputLayout
            return ASHVideoOutputContractV4(
                raster: raster,
                codecID: request.outputCodec.rawValue,
                encodedFormatDescriptor: encodedDescriptor,
                pixelFormatID: layout.rawValue,
                bitDepth: UInt8(layout.signalBitDepth),
                range: .full,
                chromaSubsampling: .rgb,
                chromaSiting: .notApplicable,
                alphaModel: source.pixel.alphaModel,
                color: source.color
            )
        case .opaque(let writerContract):
        let range: CanonicalPixelRangeV4 =
            writerContract.storage.codeRange == .video ? .video : .full
        let color: CanonicalColorStateV4
        switch writerContract.color {
        case .sdrBT709:
            color = CanonicalColorStateV4(
                primaries:
                    kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
                transferFunction:
                    kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
                matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
                masteringDisplay: nil,
                contentLightLevel: nil,
                dynamicHDRMetadata: []
            )
        case .hdr:
            color = source.color
        }
        return ASHVideoOutputContractV4(
            raster: raster,
            codecID: request.outputCodec.rawValue,
            encodedFormatDescriptor: encodedDescriptor,
            pixelFormatID: writerContract.storage.rawValue,
            bitDepth: UInt8(writerContract.storage.signalBitDepth),
            range: range,
            chromaSubsampling: .yuv420,
            chromaSiting: source.pixel.chromaSiting,
            alphaModel: .none,
            color: color
        )
        }
    }

    func audioOmissionApproval(
        input: CanonicalInputIdentityV4,
        request: UpscaleRequest
    ) -> ASHSHA256V4 {
        ASHSHA256V4(rawData: Data(
            [
                "ash-audio-omission-approval-v4",
                input.contentSHA256.rawValue,
                String(request.targetWidth),
                String(request.targetHeight),
                request.outputCodec.rawValue,
                Self.audioOmissionReasonID
            ].joined(separator: "|").utf8
        ))
    }

    func nominalFrameDuration(
        source: VideoInfo,
        track: MediaTrackNodeV4
    ) throws -> ExactRationalV4 {
        if let duration = source.minimumFrameDuration,
           duration.isNumeric,
           duration.value > 0,
           duration.timescale > 0 {
            return try ASHExactCMTimeV4.convert(
                duration,
                path: "deterministic_v4.nominal_frame_duration"
            )
        }
        if let rate = source.nominalFrameRate,
           rate.isFinite,
           rate > 0 {
            let scale: Int64 = 1_000_000
            let numerator = Int64((Double(rate) * Double(scale)).rounded())
            if numerator > 0 {
                return try ExactRationalV4(scale, numerator)
            }
        }
        if track.timebase.isPositive {
            return track.timebase
        }
        throw DeterministicV4WholeAssetPlannerError
            .invalidNominalFrameDuration
    }

    func verifyPlanAgreement(
        pairings: [TrackPair],
        canonicalMedia: CanonicalMediaStateV4,
        ashPlan: ASHIdentifiedExecutionPlanV4,
        trackPlan: MediaTrackGraphIdentifiedPlanV4
    ) throws {
        let ashByOrdinal = Dictionary(
            uniqueKeysWithValues: ashPlan.plan.tracks.map {
                ($0.sourceIdentity.ordinal, $0.action)
            }
        )
        let graphByOrdinal = Dictionary(
            uniqueKeysWithValues: trackPlan.plan.tracks.map {
                ($0.source.identity.ordinal, $0.action)
            }
        )
        for pairing in pairings where pairing.canonical.enabled {
            let ordinal = pairing.canonical.identity.ordinal
            guard let ash = ashByOrdinal[ordinal],
                  let graph = graphByOrdinal[ordinal],
                  ash.corresponds(to: graph) else {
                throw DeterministicV4WholeAssetPlannerError
                    .ashAndTrackPlansDisagree(ordinal: ordinal)
            }
        }
        let virtualEnabled = canonicalMedia.tracks.filter {
            $0.enabled && Int($0.identity.ordinal) >= pairings.count
        }
        guard virtualEnabled.allSatisfy({
            ashByOrdinal[$0.identity.ordinal] == .passThrough
        }) else {
            throw DeterministicV4WholeAssetPlannerError
                .canonicalAndTrackGraphInventoriesDiffer
        }
    }
}

private extension CanonicalMediaTrackKindV4 {
    var graphKind: MediaTrackKindV4 {
        switch self {
        case .video: .video
        case .audio: .audio
        case .subtitle: .subtitle
        case .caption: .caption
        case .chapter: .chapter
        case .timecode: .timecode
        case .timedMetadata: .timedMetadata
        case .auxiliaryMetadata: .auxiliary
        case .unknown: .unknown
        }
    }
}

private extension ASHTrackActionV4 {
    func corresponds(to action: MediaTrackActionV4) -> Bool {
        switch (self, action) {
        case (.processVideo, .process),
             (.transcode, .transcode),
             (.passThrough, .passThrough),
             (.dropWithApproval, .dropWithConsent):
            true
        default:
            false
        }
    }
}
