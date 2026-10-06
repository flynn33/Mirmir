import AVFoundation
import AudioToolbox
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
    case nonVideoTrackRequiresExplicitTranscode(
        trackID: MediaTrackStableIDV4,
        mediaSubtypeID: String
    )
    case audioTranscodeCalibrationFailed(MediaTrackStableIDV4, reason: String)
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
    let nonVideoTranscodeHooks: [
        AVFoundationNonVideoTrackTranscodeHookV4
    ]

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

    func verifyProcessedOutput(
        at url: URL
    ) async throws -> AlphaVideoWriterVerificationV4? {
        guard case .alpha(let delivery) = videoDelivery else { return nil }
        let videoTracks = sourceGraph.tracks.filter { $0.kind == .video }
        guard let ordinal = videoTracks.firstIndex(where: {
            $0.identity.stableID == primaryGraphTrack.identity.stableID
        }) else {
            throw DeterministicV4WholeAssetPlannerError.primaryVideoMissing
        }
        return try await delivery.verifyMigratedOutput(
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
    private let audioFormatCalibrator: AVFoundationAACFormatCalibratorV4

    init(
        canonicalAdapter: AVCanonicalMediaStateAdapterV4 = .init(),
        formatCalibrator: AVFoundationVideoFormatCalibratorV4 = .init(),
        alphaDeliveryPlanner: DeterministicAlphaVideoDeliveryPlannerV4 = .init(),
        audioFormatCalibrator: AVFoundationAACFormatCalibratorV4 = .init()
    ) {
        self.canonicalAdapter = canonicalAdapter
        self.formatCalibrator = formatCalibrator
        self.alphaDeliveryPlanner = alphaDeliveryPlanner
        self.audioFormatCalibrator = audioFormatCalibrator
    }

    nonisolated static func nominalFrameDuration(
        nominalFrameRate: Float?,
        minimumFrameDuration: CMTime?,
        fallbackTimebase: ExactRationalV4
    ) throws -> ExactRationalV4 {
        if let rate = nominalFrameRate,
           rate.isFinite,
           rate > 0 {
            let ntscRate = Float(24_000.0 / 1_001.0)
            let tolerance = max(rate.ulp, ntscRate.ulp)
            if abs(rate - ntscRate) <= tolerance {
                return try ExactRationalV4(1_001, 24_000)
            }
            // Short tracks can report an averaged rate affected by their
            // rounded terminal tick. A tick must distinguish the NTSC and
            // 24 fps periods (which differ by 1/24000 second).
            // Require an unambiguous duration clock and the closer period;
            // the decoded samples must still pass the exact cadence validator.
            if let duration = minimumFrameDuration,
               duration.isNumeric,
               duration.value > 0,
               duration.timescale >= 24_000,
               !duration.flags.contains(.hasBeenRounded) {
                let ntscDuration = CMTime(value: 1_001, timescale: 24_000)
                let advertisedDuration = 1 / Double(rate)
                let ntscDifference = abs(
                    advertisedDuration - CMTimeGetSeconds(ntscDuration)
                )
                let clock = MediaClockConversionPolicyV4.self
                if clock.isExactOrAdjacentClockQuantization(
                    duration, of: ntscDuration
                ), !clock.isExactOrAdjacentClockQuantization(
                    duration, of: CMTime(value: 1, timescale: 24)
                ), ntscDifference <= 1 / Double(duration.timescale),
                   ntscDifference < abs(
                    advertisedDuration - CMTimeGetSeconds(duration)
                   ) {
                    return try ExactRationalV4(1_001, 24_000)
                }
            }
        }
        if let duration = minimumFrameDuration,
           duration.isNumeric,
           duration.value > 0,
           duration.timescale > 0 {
            return try ASHExactCMTimeV4.convert(
                duration,
                path: "deterministic_v4.nominal_frame_duration"
            )
        }
        if let rate = nominalFrameRate,
           rate.isFinite,
           rate > 0 {
            let scale: Int64 = 1_000_000
            let numerator = Int64((Double(rate) * Double(scale)).rounded())
            if numerator > 0 {
                return try ExactRationalV4(scale, numerator)
            }
        }
        if fallbackTimebase.isPositive {
            return fallbackTimebase
        }
        throw DeterministicV4WholeAssetPlannerError
            .invalidNominalFrameDuration
    }

    func prepare(
        request: UpscaleRequest,
        source: VideoInfo,
        backend: any PreparedDeterministicV4RuntimePlanningBackend,
        cancellation: ProcessingCancellation? = nil
    ) async throws -> DeterministicV4PreparedAssetPlan {
        try checkCancellation(cancellation)
        let bookmarkDocumentSHA256 = ASHSHA256V4(rawData: Data(
            (Self.ephemeralBookmarkReference + "|v1").utf8
        ))
        let canonicalProbe = try await canonicalAdapter.probe(.init(
            url: request.inputURL,
            bookmarkReference: Self.ephemeralBookmarkReference,
            bookmarkDocumentSHA256: bookmarkDocumentSHA256,
            scanDynamicHDRMetadata: true
        ))
        try checkCancellation(cancellation)
        let canonicalMedia = try canonicalProbe.requireAdmittedState()
        let asset = AVURLAsset(
            url: request.inputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let physicalTrackCount = try await asset.load(.tracks).count
        try checkCancellation(cancellation)
        let graph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: asset
        )
        try checkCancellation(cancellation)
        let pairings = try reconcile(
            canonicalMedia: canonicalMedia,
            graph: graph,
            physicalTrackCount: physicalTrackCount
        )
        guard let primaryPair = pairings.first(where: {
            $0.canonical.enabled && $0.canonical.kind == .video
        }) else {
            throw DeterministicV4WholeAssetPlannerError.primaryVideoMissing
        }
        guard let sourceVideo = primaryPair.canonical.video else {
            throw DeterministicV4WholeAssetPlannerError.primaryVideoMissing
        }

        let nonVideoPolicy = try await makeNonVideoPolicy(
            asset: asset,
            pairings: pairings,
            preserveAudio: request.preserveAudio,
            cancellation: cancellation
        )
        try checkCancellation(cancellation)

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
            approvalSHA256: approvalSHA256,
            transcodeByCanonicalOrdinal:
                nonVideoPolicy.transcodeByCanonicalOrdinal
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
            approvalSHA256: approvalSHA256,
            transcodeByGraphTrackID: nonVideoPolicy.transcodeByGraphTrackID
        )
        let baseTrackPlan = try MediaTrackGraphPlannerV4.makePlan(
            source: graph,
            request: graphRequest
        )
        let trackPlan = try baseTrackPlan.applyingTranscodePrimingDurations(
            nonVideoPolicy.transcodeByGraphTrackID.mapValues(
                \.encoderPrimingDuration
            )
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
            nominalSourceFrameDuration: try Self.nominalFrameDuration(
                nominalFrameRate: source.nominalFrameRate,
                minimumFrameDuration: source.minimumFrameDuration,
                fallbackTimebase: primaryPair.graph.timebase
            ),
            nonVideoTranscodeHooks: nonVideoPolicy.hooks
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

    struct NonVideoTranscodeDecision {
        let codecID: String
        let targetFormat: MediaTrackFormatDescriptorV4
        let encoderPrimingDuration: ExactRationalV4
        let hook: AVFoundationNonVideoTrackTranscodeHookV4
    }

    struct NonVideoPolicy {
        let transcodeByCanonicalOrdinal: [
            UInt32: NonVideoTranscodeDecision
        ]
        let transcodeByGraphTrackID: [
            MediaTrackStableIDV4: NonVideoTranscodeDecision
        ]
        let hooks: [AVFoundationNonVideoTrackTranscodeHookV4]
    }

    func reconcile(
        canonicalMedia: CanonicalMediaStateV4,
        graph: MediaTrackGraphV4,
        physicalTrackCount: Int
    ) throws -> [TrackPair] {
        guard physicalTrackCount >= 0,
              graph.tracks.count == physicalTrackCount,
              canonicalMedia.tracks.count >= physicalTrackCount else {
            throw DeterministicV4WholeAssetPlannerError
                .canonicalAndTrackGraphInventoriesDiffer
        }
        return try graph.tracks.enumerated().map { index, node in
            let canonical = canonicalMedia.tracks[index]
            guard Int(canonical.identity.ordinal) == index,
                  Int(node.identity.ordinal) == index else {
                throw DeterministicV4WholeAssetPlannerError
                    .canonicalAndTrackGraphInventoriesDiffer
            }
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

    func makeNonVideoPolicy(
        asset: AVAsset,
        pairings: [TrackPair],
        preserveAudio: Bool,
        cancellation: ProcessingCancellation? = nil
    ) async throws -> NonVideoPolicy {
        try checkCancellation(cancellation)
        let assetTracks = try await asset.load(.tracks)
        try checkCancellation(cancellation)
        guard assetTracks.count == pairings.count else {
            throw DeterministicV4WholeAssetPlannerError
                .canonicalAndTrackGraphInventoriesDiffer
        }
        var byCanonical: [UInt32: NonVideoTranscodeDecision] = [:]
        var byGraph: [
            MediaTrackStableIDV4: NonVideoTranscodeDecision
        ] = [:]
        var hooks: [AVFoundationNonVideoTrackTranscodeHookV4] = []
        for (pairing, assetTrack) in zip(pairings, assetTracks) {
            try checkCancellation(cancellation)
            guard pairing.graph.kind != .video else { continue }
            if pairing.graph.kind == .audio, !preserveAudio {
                // An explicitly approved audio omission wins over migration
                // policy; do not decode or calibrate a lane that will not be
                // present in the output.
                continue
            }
            if try await isMOVPassThroughCompatible(
                assetTrack,
                graphTrack: pairing.graph
            ) {
                continue
            }
            guard pairing.graph.kind == .audio else {
                throw DeterministicV4WholeAssetPlannerError
                    .nonVideoTrackRequiresExplicitTranscode(
                        trackID: pairing.graph.identity.stableID,
                        mediaSubtypeID: pairing.graph.formatDescriptors
                            .first?.mediaSubtypeID ?? "missing"
                    )
            }
            let calibration = try await audioFormatCalibrator.calibrate(
                asset: asset,
                track: assetTrack,
                trackID: pairing.graph.identity.stableID,
                cancellation: cancellation
            )
            let decision = NonVideoTranscodeDecision(
                codecID: "aac",
                targetFormat: calibration.targetFormat,
                encoderPrimingDuration: calibration.encoderPrimingDuration,
                hook: calibration.hook
            )
            byCanonical[pairing.canonical.identity.ordinal] = decision
            byGraph[pairing.graph.identity.stableID] = decision
            hooks.append(calibration.hook)
        }
        return NonVideoPolicy(
            transcodeByCanonicalOrdinal: byCanonical,
            transcodeByGraphTrackID: byGraph,
            hooks: hooks
        )
    }

    func checkCancellation(
        _ cancellation: ProcessingCancellation?
    ) throws {
        try cancellation?.check()
        try Task.checkCancellation()
    }

    func isMOVPassThroughCompatible(
        _ track: AVAssetTrack,
        graphTrack: MediaTrackNodeV4
    ) async throws -> Bool {
        let descriptions = try await track.load(.formatDescriptions)
        guard !descriptions.isEmpty,
              descriptions.count == graphTrack.formatDescriptors.count,
              graphTrack.formatDescriptors.allSatisfy({
                  $0.completeness == .complete
              }),
              descriptionsAreCompatible(descriptions) else {
            return false
        }
        if track.mediaType == .auxiliaryPicture {
            return try writerAccepts(
                mediaType: track.mediaType,
                sourceFormatHint: nil
            )
        }
        let formatType = CMFormatDescriptionGetMediaType(descriptions[0])
        guard track.mediaType.rawValue == fourCCString(formatType) else {
            return false
        }
        return try writerAccepts(
            mediaType: track.mediaType,
            sourceFormatHint: descriptions.count == 1 ? descriptions[0] : nil
        )
    }

    func descriptionsAreCompatible(
        _ descriptions: [CMFormatDescription]
    ) -> Bool {
        guard let reference = descriptions.first else { return false }
        let mediaType = CMFormatDescriptionGetMediaType(reference)
        let subtype = CMFormatDescriptionGetMediaSubType(reference)
        return descriptions.dropFirst().allSatisfy { description in
            guard CMFormatDescriptionGetMediaType(description) == mediaType,
                  CMFormatDescriptionGetMediaSubType(description) == subtype
            else { return false }
            switch mediaType {
            case kCMMediaType_Video:
                let lhs = CMVideoFormatDescriptionGetDimensions(reference)
                let rhs = CMVideoFormatDescriptionGetDimensions(description)
                return lhs.width == rhs.width && lhs.height == rhs.height
            case kCMMediaType_Audio:
                guard let lhs =
                        CMAudioFormatDescriptionGetStreamBasicDescription(
                            reference
                        )?.pointee,
                      let rhs =
                        CMAudioFormatDescriptionGetStreamBasicDescription(
                            description
                        )?.pointee else {
                    return false
                }
                return lhs.mSampleRate == rhs.mSampleRate
                    && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            default:
                return true
            }
        }
    }

    func writerAccepts(
        mediaType: AVMediaType,
        sourceFormatHint: CMFormatDescription?
    ) throws -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-v4-mov-preflight-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try AVAssetWriter(
            outputURL: directory.appendingPathComponent("preflight.mov"),
            fileType: .mov
        )
        guard writer.availableMediaTypes.contains(mediaType) else {
            return false
        }
        let input = AVAssetWriterInput(
            mediaType: mediaType,
            outputSettings: nil,
            sourceFormatHint: sourceFormatHint
        )
        return writer.canAdd(input)
    }

    func fourCCString(_ value: FourCharCode) -> String {
        String(bytes: [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ], encoding: .macOSRoman) ?? ""
    }

    func makeASHRequest(
        canonicalMedia: CanonicalMediaStateV4,
        primaryOrdinal: UInt32,
        request: UpscaleRequest,
        backend: any PreparedDeterministicV4RuntimePlanningBackend,
        videoDelivery: DeterministicV4VideoDeliveryPlan,
        encodedDescriptor: MediaTrackFormatDescriptorV4,
        approvalSHA256: ASHSHA256V4,
        transcodeByCanonicalOrdinal: [
            UInt32: NonVideoTranscodeDecision
        ]
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
                if let transcode =
                    transcodeByCanonicalOrdinal[track.identity.ordinal] {
                    return ASHTrackDirectiveV4(
                        trackID: track.identity.persistentID,
                        action: .transcode,
                        videoOutput: nil,
                        outputCodecID: transcode.codecID,
                        dropReasonID: nil,
                        dropApprovalSHA256: nil
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
        approvalSHA256: ASHSHA256V4,
        transcodeByGraphTrackID: [
            MediaTrackStableIDV4: NonVideoTranscodeDecision
        ]
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
            if let transcode =
                transcodeByGraphTrackID[track.identity.stableID] {
                return MediaTrackDirectiveV4(
                    trackID: track.identity.stableID,
                    action: .transcode,
                    targetFormatDescriptors: [transcode.targetFormat],
                    dropConsent: nil
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
              video.color.ambientViewingEnvironment == nil,
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
        case .proRes422: codec = .proRes422
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
                  color.ambientViewingEnvironment == nil,
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
        let ambient = try color.ambientViewingEnvironment.map(
            makeAmbientViewingEnvironment
        )
        return .hdr(HDRFormatMetadataV4(
            signal: try HDRSignalV4(
                storage: storage,
                transferFunction: transfer
            ),
            staticMetadata: HDRStaticMetadataV4(
                masteringDisplayColorVolume: mastering,
                contentLightLevelInfo: contentLight,
                ambientViewingEnvironment: ambient
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

    func makeAmbientViewingEnvironment(
        _ source: CanonicalAmbientViewingEnvironmentV4
    ) throws -> AmbientViewingEnvironmentV4 {
        try AmbientViewingEnvironmentV4(
            ambientIlluminance: try scaledUInt32(
                source.ambientIlluminance,
                by: 10_000
            ),
            ambientLight: try HDRChromaticityV4(
                x: scaledUInt16(source.ambientLightX, by: 50_000),
                y: scaledUInt16(source.ambientLightY, by: 50_000),
                label: "ambient_light"
            )
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
                ambientViewingEnvironment: nil,
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

struct AVFoundationAACCalibrationV4: @unchecked Sendable {
    let targetFormat: MediaTrackFormatDescriptorV4
    let encoderPrimingDuration: ExactRationalV4
    let hook: AVFoundationNonVideoTrackTranscodeHookV4
}

actor AVFoundationAACFormatCalibratorV4 {
    private struct CacheKey: Hashable {
        let sampleRateBitPattern: UInt64
        let channels: UInt32
        let sourceFormatFingerprints: [ASHSHA256V4]
        let channelLayoutSHA256: ASHSHA256V4?
    }

    private struct CachedOutput {
        let targetFormat: MediaTrackFormatDescriptorV4
        let encoderPrimingDuration: ExactRationalV4
    }

    private var outputs: [CacheKey: CachedOutput] = [:]

    /// Release-qualification visibility for proving that materially distinct
    /// source layouts never share an encoder calibration result.
    func cachedOutputCountForQualification() -> Int {
        outputs.count
    }

    func calibrate(
        asset: AVAsset,
        track: AVAssetTrack,
        trackID: MediaTrackStableIDV4,
        cancellation: ProcessingCancellation? = nil
    ) async throws -> AVFoundationAACCalibrationV4 {
        try checkCancellation(cancellation)
        let descriptions = try await track.load(.formatDescriptions)
        try checkCancellation(cancellation)
        guard let description = descriptions.first,
              let stream =
                CMAudioFormatDescriptionGetStreamBasicDescription(
                    description
                )?.pointee,
              stream.mSampleRate.isFinite,
              stream.mSampleRate > 0,
              (1...8).contains(Int(stream.mChannelsPerFrame)) else {
            throw DeterministicV4WholeAssetPlannerError
                .audioTranscodeCalibrationFailed(
                    trackID,
                    reason: "unsupported_source_audio_layout"
                )
        }
        let sampleRate = stream.mSampleRate
        let channels = stream.mChannelsPerFrame
        let sourceChannelLayout = try canonicalChannelLayout(
            description,
            channels: channels,
            trackID: trackID
        )
        let encoderChannelLayout = try canonicalAACChannelLayout(
            sourceLayout: sourceChannelLayout,
            channels: channels,
            trackID: trackID
        )
        let sourceFormatFingerprints = try descriptions.enumerated().map {
            ordinal, description in
            try AVFoundationTrackGraphAdapterV4.canonicalFormatDescriptor(
                description,
                ordinal: UInt32(ordinal)
            ).canonicalFingerprint
        }
        var readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        var writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVEncoderBitRateKey: min(
                512_000,
                max(64_000, 96_000 * Int(channels))
            )
        ]
        if let encoderChannelLayout {
            // Request PCM in the AAC encoder's canonical channel order. The
            // audio converter performs a pure reorder from the source layout;
            // no speaker is mixed, synthesized, or discarded.
            readerSettings[AVChannelLayoutKey] = encoderChannelLayout
            writerSettings[AVChannelLayoutKey] = encoderChannelLayout
        }
        let key = CacheKey(
            sampleRateBitPattern: sampleRate.bitPattern,
            channels: channels,
            sourceFormatFingerprints: sourceFormatFingerprints,
            channelLayoutSHA256: sourceChannelLayout.map(
                ASHSHA256V4.init(rawData:)
            )
        )
        let output: CachedOutput
        if let cached = outputs[key] {
            output = cached
        } else {
            output = try await encodeCalibration(
                asset: asset,
                track: track,
                trackID: trackID,
                readerSettings: readerSettings,
                writerSettings: writerSettings,
                cancellation: cancellation
            )
            outputs[key] = output
        }
        return AVFoundationAACCalibrationV4(
            targetFormat: output.targetFormat,
            encoderPrimingDuration: output.encoderPrimingDuration,
            hook: AVFoundationNonVideoTrackTranscodeHookV4(
                trackID: trackID,
                readerOutputSettings: readerSettings,
                writerOutputSettings: writerSettings,
                declaredOutputFormats: [output.targetFormat]
            )
        )
    }

    private func encodeCalibration(
        asset: AVAsset,
        track: AVAssetTrack,
        trackID: MediaTrackStableIDV4,
        readerSettings: [String: Any],
        writerSettings: [String: Any],
        cancellation: ProcessingCancellation?
    ) async throws -> CachedOutput {
        try checkCancellation(cancellation)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-v4-aac-calibration-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        } catch {
            throw DeterministicV4WholeAssetPlannerError
                .audioTranscodeCalibrationFailed(
                    trackID,
                    reason: "temporary_directory_creation_failed"
                )
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("calibration.mov")

        var activeReader: AVAssetReader?
        var activeWriter: AVAssetWriter?
        do {
            try checkCancellation(cancellation)
            let reader = try AVAssetReader(asset: asset)
            activeReader = reader
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: readerSettings
            )
            output.alwaysCopiesSampleData = true
            guard reader.canAdd(output) else {
                throw DeterministicV4WholeAssetPlannerError
                    .audioTranscodeCalibrationFailed(
                        trackID,
                        reason: "reader_rejected_linear_pcm_settings"
                    )
            }
            reader.add(output)
            guard reader.startReading(),
                  let first = output.copyNextSampleBuffer() else {
                throw DeterministicV4WholeAssetPlannerError
                    .audioTranscodeCalibrationFailed(
                        trackID,
                        reason: "reader_produced_no_calibration_sample"
                    )
            }
            try checkCancellation(cancellation)

            let writer = try AVAssetWriter(
                outputURL: outputURL,
                fileType: .mov
            )
            activeWriter = writer
            guard writer.canApply(
                outputSettings: writerSettings,
                forMediaType: .audio
            ) else {
                throw DeterministicV4WholeAssetPlannerError
                    .audioTranscodeCalibrationFailed(
                        trackID,
                        reason: "writer_rejected_aac_settings"
                    )
            }
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: writerSettings
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw DeterministicV4WholeAssetPlannerError
                    .audioTranscodeCalibrationFailed(
                        trackID,
                        reason: "writer_rejected_audio_input"
                    )
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw DeterministicV4WholeAssetPlannerError
                    .audioTranscodeCalibrationFailed(
                        trackID,
                        reason: "writer_start_failed"
                    )
            }
            let start = CMSampleBufferGetPresentationTimeStamp(first)
            writer.startSession(atSourceTime: start.isNumeric ? start : .zero)
            var sample: CMSampleBuffer? = first
            var appended = 0
            while let current = sample, appended < 32 {
                try checkCancellation(cancellation)
                while !input.isReadyForMoreMediaData {
                    try checkCancellation(cancellation)
                    guard writer.status != .failed,
                          reader.status != .failed else {
                        throw DeterministicV4WholeAssetPlannerError
                            .audioTranscodeCalibrationFailed(
                                trackID,
                                reason: "calibration_io_failed"
                            )
                    }
                    try await Task.sleep(for: .milliseconds(1))
                }
                guard input.append(current) else {
                    throw DeterministicV4WholeAssetPlannerError
                        .audioTranscodeCalibrationFailed(
                            trackID,
                            reason: "calibration_append_failed"
                        )
                }
                appended += 1
                if appended < 32 {
                    sample = output.copyNextSampleBuffer()
                }
            }
            if appended == 32 {
                if reader.status == .reading { reader.cancelReading() }
            } else {
                guard reader.status == .completed else {
                    throw DeterministicV4WholeAssetPlannerError
                        .audioTranscodeCalibrationFailed(
                            trackID,
                            reason: "calibration_reader_failed"
                        )
                }
            }
            try checkCancellation(cancellation)
            input.markAsFinished()
            await withCheckedContinuation { continuation in
                writer.finishWriting { continuation.resume() }
            }
            try checkCancellation(cancellation)
            guard writer.status == .completed else {
                throw DeterministicV4WholeAssetPlannerError
                    .audioTranscodeCalibrationFailed(
                        trackID,
                        reason: "calibration_finish_failed"
                    )
            }
            let graph = try await AVFoundationTrackGraphAdapterV4.probe(
                asset: AVURLAsset(url: outputURL)
            )
            try checkCancellation(cancellation)
            guard let audio = graph.tracks.first(where: {
                $0.kind == .audio
            }),
            let target = audio.formatDescriptors.first,
            target.completeness == .complete,
            target.mediaSubtypeID == "fourcc_61616320",
            let firstMediaEdit = audio.edits.first(where: { !$0.isEmpty }),
            let mediaRange = firstMediaEdit.source else {
                throw DeterministicV4WholeAssetPlannerError
                    .audioTranscodeCalibrationFailed(
                        trackID,
                        reason: "aac_descriptor_probe_failed"
                    )
            }
            let priming = try mediaRange.start.subtracting(
                firstMediaEdit.target.start
            )
            guard priming.numerator >= 0 else {
                throw DeterministicV4WholeAssetPlannerError
                    .audioTranscodeCalibrationFailed(
                        trackID,
                        reason: "aac_priming_probe_failed"
                    )
            }
            return CachedOutput(
                targetFormat: target,
                encoderPrimingDuration: priming
            )
        } catch let error as CancellationError {
            activeReader?.cancelReading()
            activeWriter?.cancelWriting()
            do {
                try checkCancellation(cancellation)
            } catch is CancellationError {
                throw error
            }
            throw DeterministicV4WholeAssetPlannerError
                .audioTranscodeCalibrationFailed(
                    trackID,
                    reason: "unexpected_cancellation_error"
                )
        } catch let error as DeterministicV4WholeAssetPlannerError {
            throw error
        } catch {
            throw DeterministicV4WholeAssetPlannerError
                .audioTranscodeCalibrationFailed(
                    trackID,
                    reason: "avfoundation_calibration_failed"
                )
        }
    }

    private func checkCancellation(
        _ cancellation: ProcessingCancellation?
    ) throws {
        try cancellation?.check()
        try Task.checkCancellation()
    }

    private func canonicalChannelLayout(
        _ description: CMAudioFormatDescription,
        channels: UInt32,
        trackID: MediaTrackStableIDV4
    ) throws -> Data? {
        var byteCount = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(
            description,
            sizeOut: &byteCount
        ) else {
            guard byteCount == 0, channels <= 2 else {
                throw DeterministicV4WholeAssetPlannerError
                    .audioTranscodeCalibrationFailed(
                        trackID,
                        reason: "multichannel_source_requires_channel_layout"
                    )
            }
            return nil
        }
        let minimumSize = MemoryLayout<AudioChannelLayout>.size
            - MemoryLayout<AudioChannelDescription>.size
        guard byteCount >= minimumSize else {
            throw DeterministicV4WholeAssetPlannerError
                .audioTranscodeCalibrationFailed(
                    trackID,
                    reason: "source_channel_layout_is_malformed"
                )
        }
        let tag = layout.pointee.mChannelLayoutTag
        let declaredChannels: UInt32
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            declaredChannels = layout.pointee.mNumberChannelDescriptions
            let descriptionBytes = Int(declaredChannels)
                * MemoryLayout<AudioChannelDescription>.stride
            guard byteCount >= minimumSize + descriptionBytes else {
                throw DeterministicV4WholeAssetPlannerError
                    .audioTranscodeCalibrationFailed(
                        trackID,
                        reason: "source_channel_layout_is_malformed"
                    )
            }
        } else if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            declaredChannels = UInt32(
                layout.pointee.mChannelBitmap.rawValue.nonzeroBitCount
            )
        } else {
            declaredChannels = AudioChannelLayoutTag_GetNumberOfChannels(tag)
        }
        guard declaredChannels == channels else {
            throw DeterministicV4WholeAssetPlannerError
                .audioTranscodeCalibrationFailed(
                    trackID,
                    reason: "source_channel_layout_count_mismatch"
                )
        }
        return Data(bytes: layout, count: byteCount)
    }

    private func canonicalAACChannelLayout(
        sourceLayout: Data?,
        channels: UInt32,
        trackID: MediaTrackStableIDV4
    ) throws -> Data? {
        guard channels > 2 else { return sourceLayout }
        guard let sourceLayout,
              sourceLayout.count >= MemoryLayout<AudioChannelLayoutTag>.size
        else {
            throw DeterministicV4WholeAssetPlannerError
                .audioTranscodeCalibrationFailed(
                    trackID,
                    reason: "multichannel_source_requires_channel_layout"
                )
        }
        let sourceTag = sourceLayout.withUnsafeBytes {
            $0.loadUnaligned(as: AudioChannelLayoutTag.self)
        }
        let targetTag: AudioChannelLayoutTag?
        switch channels {
        case 3:
            targetTag = kAudioChannelLayoutTag_AAC_3_0
        case 4:
            targetTag = sourceTag == kAudioChannelLayoutTag_Quadraphonic
                ? kAudioChannelLayoutTag_AAC_Quadraphonic
                : kAudioChannelLayoutTag_AAC_4_0
        case 5:
            targetTag = kAudioChannelLayoutTag_AAC_5_0
        case 6:
            targetTag = sourceTag == kAudioChannelLayoutTag_AAC_6_0
                ? kAudioChannelLayoutTag_AAC_6_0
                : kAudioChannelLayoutTag_AAC_5_1
        case 7:
            targetTag = sourceTag == kAudioChannelLayoutTag_AAC_7_0
                ? kAudioChannelLayoutTag_AAC_7_0
                : kAudioChannelLayoutTag_AAC_6_1
        case 8:
            if sourceTag == kAudioChannelLayoutTag_MPEG_7_1_C
                || sourceTag == kAudioChannelLayoutTag_AAC_7_1_B {
                targetTag = kAudioChannelLayoutTag_AAC_7_1_B
            } else if sourceTag == kAudioChannelLayoutTag_AAC_7_1_C {
                targetTag = kAudioChannelLayoutTag_AAC_7_1_C
            } else if sourceTag == kAudioChannelLayoutTag_Octagonal
                || sourceTag == kAudioChannelLayoutTag_AAC_Octagonal {
                targetTag = kAudioChannelLayoutTag_AAC_Octagonal
            } else {
                targetTag = kAudioChannelLayoutTag_AAC_7_1
            }
        default:
            targetTag = nil
        }
        guard let targetTag else {
            throw DeterministicV4WholeAssetPlannerError
                .audioTranscodeCalibrationFailed(
                    trackID,
                    reason: "source_channel_layout_has_no_aac_mapping"
                )
        }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = targetTag
        let byteCount = MemoryLayout<AudioChannelLayout>.size
            - MemoryLayout<AudioChannelDescription>.size
        let targetLayout = withUnsafePointer(to: &layout) {
            Data(bytes: $0, count: byteCount)
        }
        guard losslessChannelMapExists(
            from: sourceLayout,
            to: targetLayout,
            channels: channels
        ) else {
            throw DeterministicV4WholeAssetPlannerError
                .audioTranscodeCalibrationFailed(
                    trackID,
                    reason: "source_channel_layout_has_no_lossless_aac_mapping"
                )
        }
        return targetLayout
    }

    private func losslessChannelMapExists(
        from source: Data,
        to target: Data,
        channels: UInt32
    ) -> Bool {
        source.withUnsafeBytes { sourceBytes in
            target.withUnsafeBytes { targetBytes in
                guard let sourceBase = sourceBytes.baseAddress,
                      let targetBase = targetBytes.baseAddress else {
                    return false
                }
                let sourceLayout = sourceBase.assumingMemoryBound(
                    to: AudioChannelLayout.self
                )
                let targetLayout = targetBase.assumingMemoryBound(
                    to: AudioChannelLayout.self
                )
                let layouts = [sourceLayout, targetLayout]
                var channelMap = [Int32](
                    repeating: -1,
                    count: Int(channels)
                )
                var mapSize = UInt32(
                    channelMap.count * MemoryLayout<Int32>.size
                )
                let status = layouts.withUnsafeBytes { layoutBytes in
                    channelMap.withUnsafeMutableBytes { mapBytes in
                        AudioFormatGetProperty(
                            kAudioFormatProperty_ChannelMap,
                            UInt32(layoutBytes.count),
                            layoutBytes.baseAddress,
                            &mapSize,
                            mapBytes.baseAddress!
                        )
                    }
                }
                guard status == noErr,
                      mapSize == UInt32(
                          channelMap.count * MemoryLayout<Int32>.size
                      ) else {
                    return false
                }
                return Set(channelMap) == Set(
                    (0..<Int32(channels)).map { $0 }
                )
            }
        }
    }
}
