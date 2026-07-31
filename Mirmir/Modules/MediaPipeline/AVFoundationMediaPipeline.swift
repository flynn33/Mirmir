import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo

protocol ASHTelemetryMediaPipelineScoping: AnyObject, Sendable {
    func scoped(to telemetry: any ASHTelemetryRecording) -> any MediaPipelineService
}

final class AVFoundationMediaPipeline:
    MediaPipelineService,
    ASHTelemetryMediaPipelineScoping,
    @unchecked Sendable {

    private let metal: MetalRenderingService
    private let telemetry: any ASHTelemetryRecording
    private let outputVerifier: any OutputMediaVerifying
    private let diagnostics: MirmirDiagnosticStore?
    private let diagnosticRecorder: MirmirDiagnosticRecorder

    init(
        metal: MetalRenderingService,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared,
        outputVerifier: any OutputMediaVerifying = OutputMediaVerifier(),
        diagnostics: MirmirDiagnosticStore? = nil
    ) {
        self.metal = metal
        self.telemetry = telemetry
        self.outputVerifier = outputVerifier
        self.diagnostics = diagnostics
        self.diagnosticRecorder = MirmirDiagnosticRecorder(store: diagnostics)
    }

    func start() {}
    func stop() {}

    func scoped(to telemetry: any ASHTelemetryRecording) -> any MediaPipelineService {
        AVFoundationMediaPipeline(
            metal: metal,
            telemetry: telemetry,
            outputVerifier: outputVerifier,
            diagnostics: diagnostics
        )
    }

    func probe(url: URL) async throws -> SourceProfile {
        let stage = telemetry.beginStage(.mediaProbe)
        defer { telemetry.endStage(stage) }
        let correlationID = UUID()
        let resource = MirmirDiagnosticResourceInput(
            role: "source_video",
            url: url,
            location: .userSelected
        )
        diagnosticRecorder.enqueue(
            severity: .info,
            subsystem: "media",
            operation: "media_probe",
            code: "media_probe_started",
            correlationID: correlationID,
            resources: [resource]
        )
        var failureStage = "asset_initialization"
        do {
            let asset = AVURLAsset(
                url: url,
                options: [
                    AVURLAssetPreferPreciseDurationAndTimingKey: true
                ]
            )
            failureStage = "load_video_tracks"
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw MediaPipelineError.noVideoTrack(url)
            }
            failureStage = "load_presentation_dimensions"
            let size = try await videoTrack.load(.naturalSize)
            failureStage = "validate_presentation_dimensions"
            let resolution = try Self.presentationResolution(from: size)
            failureStage = "load_frame_rate"
            let fps = Double(try await videoTrack.load(.nominalFrameRate))
            failureStage = "load_format_descriptions"
            let formats = try await videoTrack.load(.formatDescriptions)
            failureStage = "resolve_scan_structure"
            let scanStructure =
                try MediaVideoScanStructureResolver.resolve(formats)
            failureStage = "resolve_video_format"
            let videoFormat = try await Self.resolveSupportedVideoFormat(
                track: videoTrack,
                formats: formats
            )
            failureStage = "load_duration"
            let durationCM = try await asset.load(.duration)
            failureStage = "load_audio_tracks"
            let audioTrackCount = try await asset
                .loadTracks(withMediaType: .audio)
                .count
            failureStage = "load_auxiliary_tracks"
            let subtitleTrackCount = try await Self.trackCount(
                in: asset,
                mediaTypes: [.subtitle, .text, .closedCaption]
            )
            let metadataTrackCount = try await Self.trackCount(
                in: asset,
                mediaTypes: [.metadata, .timecode]
            )
            failureStage = "load_container_metadata"
            let hasContainerMetadata = try await !asset.load(.metadata).isEmpty
            failureStage = "inspect_media_preservation"
            let mediaPreservationCapability =
                try await SourceMediaPreservationPreflight.inspect(
                    asset: asset,
                    videoTrack: videoTrack
                )

            let codedResolution = Self.codedResolution(
                from: formats.first,
                fallback: resolution
            )
            let pixelAspectRatio = Self.pixelAspectRatio(
                from: formats.first
            )
            let codecHint: String? = formats.first.map { description in
                Self.fourCCString(
                    CMFormatDescriptionGetMediaSubType(description)
                )
            }
            let rawDuration = CMTimeGetSeconds(durationCM)
            let durationSeconds = rawDuration.isFinite ? rawDuration : 0
            let estimatedFrameCount = Self.estimatedFrameCount(
                durationSeconds: durationSeconds,
                frameRate: fps
            )
            let profile = try SourceProfile(
                url: url,
                resolution: resolution,
                codedResolution: codedResolution,
                pixelAspectRatio: pixelAspectRatio,
                frameRate: fps,
                durationSeconds: durationSeconds,
                estimatedFrameCount: estimatedFrameCount,
                codecHint: codecHint,
                audioTrackCount: audioTrackCount,
                videoFormat: videoFormat,
                scanStructure: scanStructure,
                subtitleTrackCount: subtitleTrackCount,
                metadataTrackCount: metadataTrackCount,
                hasContainerMetadata: hasContainerMetadata,
                mediaPreservationCapability:
                    mediaPreservationCapability
            )
            telemetry.recordMedia(ASHMediaObservation(
                kind: "media_probe",
                details: [
                    "encoded_dimensions":
                        "\(resolution.width)x\(resolution.height)",
                    "coded_dimensions":
                        "\(codedResolution.width)x\(codedResolution.height)",
                    "estimated_frame_count":
                        String(profile.estimatedFrameCount),
                    "has_audio": String(profile.hasAudio),
                    "audio_track_count":
                        String(profile.audioTrackCount),
                    "video_format": profile.videoFormat.description,
                    "scan_structure":
                        profile.scanStructure.rawValue,
                    "subtitle_track_count":
                        String(profile.subtitleTrackCount),
                    "metadata_track_count":
                        String(profile.metadataTrackCount),
                    "has_container_metadata":
                        String(profile.hasContainerMetadata),
                    "media_preservation_verification":
                        profile.mediaPreservationCapability
                            .verificationLevel.rawValue,
                    "media_preservation_inventory":
                        profile.mediaPreservationCapability
                            .inventorySummary
                ]
            ))
            diagnosticRecorder.enqueue(
                severity: .info,
                subsystem: "media",
                operation: "media_probe",
                code: "media_probe_succeeded",
                correlationID: correlationID,
                source: profile,
                resources: [resource]
            )
            return profile
        } catch {
            diagnosticRecorder.enqueue(
                severity: .error,
                subsystem: "media",
                operation: "media_probe",
                code: "media_probe_failed_\(failureStage)",
                correlationID: correlationID,
                resources: [resource],
                error: error
            )
            throw error
        }
    }

    private static func estimatedFrameCount(
        durationSeconds: Double,
        frameRate: Double
    ) -> Int {
        guard durationSeconds.isFinite,
              frameRate.isFinite,
              durationSeconds > 0,
              frameRate > 0 else {
            return 0
        }
        let product = durationSeconds * frameRate
        guard product.isFinite else { return Int.max }
        guard product < Double(Int.max) else { return Int.max }
        return max(Int(product.rounded()), 0)
    }

    private static func presentationResolution(
        from size: CGSize
    ) throws -> VideoResolution {
        let width = abs(size.width)
        let height = abs(size.height)
        let maximumDimension = Double(Int32.max)
        guard width.isFinite,
              height.isFinite,
              width >= 1,
              height >= 1,
              width <= maximumDimension,
              height <= maximumDimension else {
            throw MediaPipelineError.invalidAssetDimensions
        }
        let roundedWidth = width.rounded()
        let roundedHeight = height.rounded()
        guard roundedWidth >= 1, roundedHeight >= 1 else {
            throw MediaPipelineError.invalidAssetDimensions
        }
        return VideoResolution(
            width: Int(roundedWidth),
            height: Int(roundedHeight)
        )
    }

    private static func codedResolution(
        from format: CMFormatDescription?,
        fallback: VideoResolution
    ) -> VideoResolution {
        guard let format,
              CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video else {
            return fallback
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width > 0, dimensions.height > 0 else {
            return fallback
        }
        return VideoResolution(
            width: Int(dimensions.width),
            height: Int(dimensions.height)
        )
    }

    private static func pixelAspectRatio(
        from format: CMFormatDescription?
    ) -> VideoPixelAspectRatio? {
        guard let format,
              let extensions = CMFormatDescriptionGetExtensions(format)
                as NSDictionary?,
              let ratio = extensions[
                kCMFormatDescriptionExtension_PixelAspectRatio
              ] as? NSDictionary,
              let horizontal = ratio[
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing
              ] as? NSNumber,
              let vertical = ratio[
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing
              ] as? NSNumber,
              horizontal.intValue > 0,
              vertical.intValue > 0 else {
            return nil
        }
        return VideoPixelAspectRatio(
            horizontalSpacing: horizontal.intValue,
            verticalSpacing: vertical.intValue
        )
    }

    func beginSession(source: SourceProfile, output: OutputProfile) async throws -> MediaSession {
        do {
            return try await telemetry.measure(.readerSetup) {
                try await AVFoundationMediaSession.make(
                    metal: metal,
                    telemetry: telemetry,
                    outputVerifier: outputVerifier,
                    source: source,
                    output: output
                )
            }
        } catch {
            diagnosticRecorder.enqueue(
                severity: .error,
                subsystem: "media",
                operation: "media_session_start",
                code: "media_session_start_failed",
                source: source,
                resources: [
                    MirmirDiagnosticResourceInput(
                        role: "source_video",
                        url: source.url,
                        location: .userSelected
                    )
                ],
                error: error
            )
            throw error
        }
    }

    fileprivate static func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    fileprivate static func resolveSupportedVideoFormat(
        track: AVAssetTrack,
        formats: [CMFormatDescription]
    ) async throws -> MediaVideoFormat {
        guard !formats.isEmpty else {
            throw MediaPipelineError.unsupportedVideoFormat(
                "the video track has no format description"
            )
        }
        let mediaCharacteristics = try await track.load(.mediaCharacteristics)
        let hasHDRCharacteristic = mediaCharacteristics.contains(
            .containsHDRVideo
        )
        let hasAlphaCharacteristic = mediaCharacteristics.contains(
            .containsAlphaChannel
        )
        var resolved: MediaVideoFormat?
        for format in formats {
            let candidate = try resolveSupportedVideoFormat(
                format: format,
                hasHDRCharacteristic: hasHDRCharacteristic,
                hasAlphaCharacteristic: hasAlphaCharacteristic
            )
            if let resolved, resolved != candidate {
                throw MediaPipelineError.unsupportedVideoFormat(
                    "the video track changes color, bit-depth, or alpha "
                        + "format within one track"
                )
            }
            resolved = candidate
        }
        return resolved ?? .sdrBT709
    }

    static func resolveSupportedVideoFormat(
        format: CMFormatDescription,
        hasHDRCharacteristic: Bool,
        hasAlphaCharacteristic: Bool
    ) throws -> MediaVideoFormat {
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        guard subtype != kCMVideoCodecType_DolbyVisionHEVC else {
            throw MediaPipelineError.unsupportedVideoFormat(
                "Dolby Vision dynamic metadata requires regeneration after "
                    + "pixel processing; supported HDR inputs are BT.2020 "
                    + "HDR10/PQ and HLG"
            )
        }
        let extensions = (
            CMFormatDescriptionGetExtensions(format) as NSDictionary?
        ) ?? [:]
        let declaredStorage = uncompressedPixelStorage(subtype)
        let containsAlpha = declaredStorage?.hasAlpha == true
            || hasAlphaCharacteristic
            || booleanValue(
                extensions[
                    kCMFormatDescriptionExtension_ContainsAlphaChannel
                        as String
                ]
            )
            || (extensions[
                kCMFormatDescriptionExtension_Depth as String
            ] as? NSNumber)?.intValue == 32
            || subtype == kCMVideoCodecType_HEVCWithAlpha
        let transfer = extensions[
            kCMFormatDescriptionExtension_TransferFunction as String
        ] as? String
        let primaries = extensions[
            kCMFormatDescriptionExtension_ColorPrimaries as String
        ] as? String
        let matrix = extensions[
            kCMFormatDescriptionExtension_YCbCrMatrix as String
        ] as? String
        let taggedColorFieldCount = [transfer, primaries, matrix]
            .compactMap { $0 }
            .count
        guard taggedColorFieldCount == 0 || taggedColorFieldCount == 3 else {
            throw MediaPipelineError.unsupportedColorProfile(
                "color primaries, transfer function, and YCbCr matrix must "
                    + "all be present together"
            )
        }
        let resolvedTransfer = try transferFunction(
            transfer,
            hasHDRCharacteristic: hasHDRCharacteristic
        )
        let resolvedPrimaries = try colorPrimaries(
            primaries,
            transferFunction: resolvedTransfer
        )
        try validateMatrix(
            matrix,
            primaries: resolvedPrimaries,
            hasTaggedColor: taggedColorFieldCount == 3
        )
        let bitsPerComponent = (
            extensions[
                kCMFormatDescriptionExtension_BitsPerComponent as String
            ] as? NSNumber
        )?.intValue
        let pixelStorage = try resolvePixelStorage(
            format: format,
            subtype: subtype,
            extensions: extensions,
            declaredStorage: declaredStorage,
            containsAlpha: containsAlpha,
            transferFunction: resolvedTransfer,
            bitsPerComponent: bitsPerComponent
        )
        if containsAlpha {
            guard pixelStorage.hasAlpha else {
                throw MediaPipelineError.unsupportedVideoFormat(
                    "the source declares alpha but its decoded storage "
                        + "\(pixelStorage.rawValue) has no alpha component"
                )
            }
            guard !resolvedTransfer.isHDR,
                  resolvedPrimaries == .bt709 else {
                throw MediaPipelineError.unsupportedVideoFormat(
                    "combined HDR and alpha processing is not supported by "
                        + "the current HEVC-with-alpha writer path"
                )
            }
            let alphaMode = try resolveAlphaMode(extensions)
            return MediaVideoFormat(
                pixelStorage: pixelStorage,
                colorPrimaries: resolvedPrimaries,
                transferFunction: resolvedTransfer,
                alphaMode: alphaMode
            )
        }
        if resolvedTransfer.isHDR {
            if pixelStorage.bitDepth < 10 {
                throw MediaPipelineError.unsupportedVideoFormat(
                    "HDR processing requires at least 10-bit decoded "
                        + "component precision"
                )
            }
            guard resolvedPrimaries == .bt2020 else {
                throw MediaPipelineError.unsupportedColorProfile(
                    "HDR transfer requires BT.2020 primaries and matrix"
                )
            }
            let mastering = extensions[
                kCMFormatDescriptionExtension_MasteringDisplayColorVolume
                    as String
            ] as? Data
            let contentLight = extensions[
                kCMFormatDescriptionExtension_ContentLightLevelInfo as String
            ] as? Data
            try validateHDRStaticMetadata(
                masteringDisplayColorVolume: mastering,
                contentLightLevelInfo: contentLight
            )
            return MediaVideoFormat(
                pixelStorage: pixelStorage,
                colorPrimaries: resolvedPrimaries,
                transferFunction: resolvedTransfer,
                masteringDisplayColorVolume: mastering,
                contentLightLevelInfo: contentLight
            )
        }
        if resolvedPrimaries == .bt2020,
           pixelStorage.bitDepth < 10 {
            throw MediaPipelineError.unsupportedVideoFormat(
                "BT.2020 SDR input must declare 10 bits per component so "
                    + "Mirmir can preserve its component precision"
            )
        }
        return MediaVideoFormat(
            pixelStorage: pixelStorage,
            colorPrimaries: resolvedPrimaries,
            transferFunction: resolvedTransfer
        )
    }

    private static func uncompressedPixelStorage(
        _ subtype: FourCharCode
    ) -> MediaVideoPixelStorage? {
        switch subtype {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return .nv12VideoRange8Bit
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return .nv12FullRange8Bit
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            return .p010VideoRange10Bit
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return .p010FullRange10Bit
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
            return .yuv422VideoRange8Bit
        case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
            return .yuv422FullRange8Bit
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
            return .yuv422VideoRange10Bit
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            return .yuv422FullRange10Bit
        case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange:
            return .yuv422VideoRange16Bit
        case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
            return .yuv444VideoRange8Bit
        case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
            return .yuv444FullRange8Bit
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
            return .yuv444VideoRange10Bit
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return .yuv444FullRange10Bit
        case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
            return .yuv444VideoRange16Bit
        case kCVPixelFormatType_4444AYpCbCr8:
            return .yuv444VideoRange8BitWithAlpha
        case kCVPixelFormatType_4444AYpCbCr16:
            return .yuv444VideoRange16BitWithAlpha
        case kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar:
            return .yuv444VideoRange16BitWithAlphaTriPlanar
        case kCMPixelFormat_32BGRA, kCMPixelFormat_32ARGB:
            return .bgra8WithAlpha
        default:
            return nil
        }
    }

    private static func resolvePixelStorage(
        format: CMFormatDescription,
        subtype: FourCharCode,
        extensions: NSDictionary,
        declaredStorage: MediaVideoPixelStorage?,
        containsAlpha: Bool,
        transferFunction: MediaVideoTransferFunction,
        bitsPerComponent: Int?
    ) throws -> MediaVideoPixelStorage {
        if let declaredStorage {
            return declaredStorage
        }
        if containsAlpha,
           (
               subtype == kCMVideoCodecType_HEVCWithAlpha
                   || subtype == kCMVideoCodecType_HEVC
           ) {
            guard bitsPerComponent == nil || bitsPerComponent == 8 else {
                throw MediaPipelineError.unsupportedVideoFormat(
                    "HEVC alpha decoded through BGRA requires 8-bit "
                        + "component precision; observed "
                        + "\(bitsPerComponent ?? -1)"
                )
            }
            return .bgra8WithAlpha
        }
        if subtype == kCMVideoCodecType_HEVC {
            let identity: HEVCEncodedFormatIdentity
            do {
                identity = try HEVCFormatIdentityReader.read(
                    formatDescription: format
                )
            } catch {
                throw MediaPipelineError.unsupportedVideoFormat(
                    "HEVC sampling and bit depth could not be read exactly "
                        + "from the sequence parameter set: \(error)"
                )
            }
            guard identity.lumaBitDepth == identity.chromaBitDepth else {
                throw MediaPipelineError.unsupportedVideoFormat(
                    "HEVC luma/chroma bit depths differ ("
                        + "\(identity.lumaBitDepth)/"
                        + "\(identity.chromaBitDepth))"
                )
            }
            let fullRange = compressedVideoFullRangeValue(
                extensions[
                    kCMFormatDescriptionExtension_FullRangeVideo as String
                ]
            )
            return try hevcPixelStorage(
                chromaSampling: identity.chromaSampling,
                bitDepth: identity.lumaBitDepth,
                fullRange: fullRange
            )
        }
        if subtype == kCMVideoCodecType_AppleProRes4444
            || subtype == kCMVideoCodecType_AppleProRes4444XQ {
            if containsAlpha {
                return .yuv444VideoRange16BitWithAlphaTriPlanar
            }
            if transferFunction.isHDR {
                return .yuv444FullRange10Bit
            }
            if compressedVideoFullRangeValue(
                extensions[
                    kCMFormatDescriptionExtension_FullRangeVideo as String
                ]
            ) {
                guard (bitsPerComponent ?? 10) <= 10 else {
                    throw MediaPipelineError.unsupportedVideoFormat(
                        "full-range ProRes 4444 above 10 decoded bits has "
                            + "no exact executable full-range storage"
                    )
                }
                return .yuv444FullRange10Bit
            }
            return .yuv444VideoRange16Bit
        }
        if subtype == kCMVideoCodecType_AppleProRes422Proxy
            || subtype == kCMVideoCodecType_AppleProRes422LT
            || subtype == kCMVideoCodecType_AppleProRes422
            || subtype == kCMVideoCodecType_AppleProRes422HQ {
            return .yuv422VideoRange10Bit
        }
        let fullRange = compressedVideoFullRangeValue(
            extensions[
                kCMFormatDescriptionExtension_FullRangeVideo as String
            ]
        )
        switch bitsPerComponent {
        case .some(let bits) where bits > 10:
            throw MediaPipelineError.unsupportedVideoFormat(
                "\(bits)-bit compressed input does not declare a supported "
                    + "decoded pixel-storage identity"
            )
        case .some(10):
            return fullRange
                ? .p010FullRange10Bit
                : .p010VideoRange10Bit
        default:
            return fullRange
                ? .nv12FullRange8Bit
                : .nv12VideoRange8Bit
        }
    }

    private static func hevcPixelStorage(
        chromaSampling: HEVCChromaSampling,
        bitDepth: Int,
        fullRange: Bool
    ) throws -> MediaVideoPixelStorage {
        guard (8...10).contains(bitDepth) else {
            throw MediaPipelineError.unsupportedVideoFormat(
                "HEVC \(bitDepth)-bit precision has no exact executable "
                    + "decoded storage"
            )
        }
        let isTenBit = bitDepth > 8
        switch chromaSampling {
        case .monochrome:
            throw MediaPipelineError.unsupportedVideoFormat(
                "monochrome HEVC has no executable YCbCr processing layout"
            )
        case .yuv420:
            if isTenBit {
                return fullRange
                    ? .p010FullRange10Bit
                    : .p010VideoRange10Bit
            }
            return fullRange
                ? .nv12FullRange8Bit
                : .nv12VideoRange8Bit
        case .yuv422:
            if isTenBit {
                return fullRange
                    ? .yuv422FullRange10Bit
                    : .yuv422VideoRange10Bit
            }
            return fullRange
                ? .yuv422FullRange8Bit
                : .yuv422VideoRange8Bit
        case .yuv444:
            if isTenBit {
                return fullRange
                    ? .yuv444FullRange10Bit
                    : .yuv444VideoRange10Bit
            }
            return fullRange
                ? .yuv444FullRange8Bit
                : .yuv444VideoRange8Bit
        }
    }

    private static func validateHDRStaticMetadata(
        masteringDisplayColorVolume: Data?,
        contentLightLevelInfo: Data?
    ) throws {
        if let masteringDisplayColorVolume,
           masteringDisplayColorVolume.count != 24 {
            throw MediaPipelineError.unsupportedVideoFormat(
                "HDR mastering-display metadata must contain exactly "
                    + "24 bytes; observed "
                    + "\(masteringDisplayColorVolume.count)"
            )
        }
        if let contentLightLevelInfo,
           contentLightLevelInfo.count != 4 {
            throw MediaPipelineError.unsupportedVideoFormat(
                "HDR content-light metadata must contain exactly 4 bytes; "
                    + "observed \(contentLightLevelInfo.count)"
            )
        }
    }

    private static func transferFunction(
        _ value: String?,
        hasHDRCharacteristic: Bool
    ) throws -> MediaVideoTransferFunction {
        if value == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            as String {
            return .pq
        }
        if value == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            as String {
            return .hlg
        }
        if value == nil
            || value == kCMFormatDescriptionTransferFunction_ITU_R_709_2
                as String {
            guard !hasHDRCharacteristic else {
                throw MediaPipelineError.unsupportedColorProfile(
                    "the track declares HDR but has no PQ or HLG transfer tag"
                )
            }
            return .bt709
        }
        throw MediaPipelineError.unsupportedColorProfile(
            "unsupported transfer function \(value ?? "missing")"
        )
    }

    private static func colorPrimaries(
        _ value: String?,
        transferFunction: MediaVideoTransferFunction
    ) throws -> MediaVideoColorPrimaries {
        if value == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String {
            return .bt2020
        }
        if value == nil
            || value == kCMFormatDescriptionColorPrimaries_ITU_R_709_2
                as String {
            guard !transferFunction.isHDR else {
                throw MediaPipelineError.unsupportedColorProfile(
                    "HDR input must declare BT.2020 color primaries"
                )
            }
            return .bt709
        }
        throw MediaPipelineError.unsupportedColorProfile(
            "unsupported color primaries \(value ?? "missing")"
        )
    }

    private static func validateMatrix(
        _ value: String?,
        primaries: MediaVideoColorPrimaries,
        hasTaggedColor: Bool
    ) throws {
        guard hasTaggedColor else { return }
        let expected = primaries == .bt2020
            ? kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String
            : kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String
        guard value == expected else {
            throw MediaPipelineError.unsupportedColorProfile(
                "YCbCr matrix \(value ?? "missing") does not match "
                    + "\(primaries.rawValue)"
            )
        }
    }

    private static func resolveAlphaMode(
        _ extensions: NSDictionary
    ) throws -> MediaVideoAlphaMode {
        let value = extensions[
            kCMFormatDescriptionExtension_AlphaChannelMode as String
        ] as? String
        if value == kCMFormatDescriptionAlphaChannelMode_StraightAlpha
            as String {
            return .straight
        }
        if value
            == kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha
                as String {
            return .premultiplied
        }
        throw MediaPipelineError.unsupportedVideoFormat(
            "the source contains alpha but does not declare straight or "
                + "premultiplied alpha semantics"
        )
    }

    private static func booleanValue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return false
        }
        return number.boolValue
    }

    private static func compressedVideoFullRangeValue(_ value: Any?) -> Bool {
        booleanValue(value)
    }

    private static func trackCount(
        in asset: AVURLAsset,
        mediaTypes: [AVMediaType]
    ) async throws -> Int {
        var result = 0
        for mediaType in mediaTypes {
            result += try await asset.loadTracks(
                withMediaType: mediaType
            ).count
        }
        return result
    }
}

enum AVFoundationSourceAssetFactory {
    static var options: [String: Any] {
        [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    }

    static func make(url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: options)
    }
}

enum AVFoundationSourceTimelinePreflight {
    static func validate(
        _ timeRange: CMTimeRange,
        mediaType: AVMediaType
    ) throws {
        let start = timeRange.start
        let end = CMTimeRangeGetEnd(timeRange)
        guard timeRange.isValid,
              start.isNumeric,
              end.isNumeric else {
            return
        }
        guard CMTimeCompare(start, .zero) >= 0 else {
            let mediaTypeIdentifier: String
            switch mediaType {
            case .video:
                mediaTypeIdentifier = "video"
            case .audio:
                mediaTypeIdentifier = "audio"
            default:
                mediaTypeIdentifier = mediaType.rawValue
            }
            throw MediaPipelineError.unsupportedNegativeSourceTimeline(
                mediaType: mediaTypeIdentifier,
                start: start,
                end: end
            )
        }
    }
}

final class AVFoundationMediaSession: MediaSession, @unchecked Sendable {
    enum LifecycleState {
        case active
        case cancelled
        case failed
        case committed
    }

    let sourceProfile: SourceProfile
    let outputProfile: OutputProfile
    let videoFormat: MediaVideoFormat
    let outputPixelBufferPool: CVPixelBufferPool
    private let deinterlacer: R13FormatPreservingDeinterlacer?

    private let asset: AVURLAsset
    private let sourceVideoEndTime: CMTime
    let reader: AVAssetReader
    private let videoOutput: AVAssetReaderTrackOutput
    let sourceAudioTracks: [AVAssetTrack]

    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let timedMetadataWriter: TimedMetadataWriter?
    let outputTransaction: AtomicMediaOutput
    let stagingFile: MediaPipelineStagingFile
    let outputVerifier: any OutputMediaVerifying
    let telemetry: any ASHTelemetryRecording
    let expectedCompressedAACTrackIdentities:
        [OutputMediaAACTrackIdentity]
    let expectedVideoTransform: CGAffineTransform
    let sourceMediaPreservation: SourceMediaPreservationPlan

    var presentationTransform: CGAffineTransform {
        expectedVideoTransform
    }

    var prepublicationOutputURL: URL {
        outputTransaction.temporaryURL
    }

    var publishedOutputIdentity: MediaOutputPublicationIdentity? {
        outputTransaction.publishedOutputIdentity
    }

    let lifecycleLock = NSLock()
    let timingLock = NSLock()
    let finalizationResourceLock = NSLock()

    private var frameIndex = 0
    private var pendingVideoSample: CMSampleBuffer?
    var lifecycleState = LifecycleState.active
    var timingLedger = FrameTimingLedger()
    var storedTerminalCleanupError: MediaPipelineError?

    var terminalCleanupError: MediaPipelineError? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return storedTerminalCleanupError
    }

    static func make(
        metal: MetalRenderingService,
        telemetry: any ASHTelemetryRecording,
        outputVerifier: any OutputMediaVerifying,
        source: SourceProfile,
        output: OutputProfile
    ) async throws -> AVFoundationMediaSession {
        let asset = AVFoundationSourceAssetFactory.make(url: source.url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw MediaPipelineError.noVideoTrack(source.url)
        }
        let videoTransform = try await videoTrack.load(.preferredTransform)
        let videoFormats = try await videoTrack.load(.formatDescriptions)
        let detectedScanStructure =
            try MediaVideoScanStructureResolver.resolve(videoFormats)
        guard detectedScanStructure == source.scanStructure else {
            throw MediaPipelineError.unsupportedVideoFormat(
                "the source profile describes scan structure "
                    + "\(source.scanStructure.rawValue), but the selected "
                    + "asset contains \(detectedScanStructure.rawValue)"
            )
        }
        let detectedVideoFormat =
            try await AVFoundationMediaPipeline.resolveSupportedVideoFormat(
                track: videoTrack,
                formats: videoFormats
            )
        guard detectedVideoFormat == source.videoFormat else {
            throw MediaPipelineError.unsupportedVideoFormat(
                "the source profile describes \(source.videoFormat), but "
                    + "the selected asset contains \(detectedVideoFormat)"
            )
        }
        let revalidatedMediaPreservation =
            try await SourceMediaPreservationPreflight.inspect(
                asset: asset,
                videoTrack: videoTrack
            )
        if source.mediaPreservationCapability.verificationLevel
                == .exactProbe,
           source.mediaPreservationCapability
                != revalidatedMediaPreservation {
            throw MediaPipelineError
                .mediaPreservationCapabilityChanged
        }
        if let reason = revalidatedMediaPreservation.failureReason(
            preserveAudio: output.preserveAudio,
            preserveSubtitles: output.preserveSubtitles,
            preserveMetadata: output.preserveMetadata
        ) {
            throw MediaPipelineError
                .mediaPreservationPreflightFailed(reason)
        }
        let videoFormat = output.videoFormat ?? source.videoFormat
        guard videoFormat == source.videoFormat else {
            throw MediaPipelineError.unsupportedVideoFormatConversion(
                source: source.videoFormat,
                requested: videoFormat
            )
        }
        guard videoFormat.supports(outputCodec: output.codec) else {
            throw MediaPipelineError.outputCodecCannotPreserveVideoFormat(
                codec: output.codec,
                format: videoFormat
            )
        }
        let outputPathExtension = output.url.pathExtension.lowercased()
        if let containerError =
                MediaOutputContainerPolicy.validationError(
                    pathExtension: outputPathExtension,
                    codec: output.codec,
                    videoFormat: videoFormat,
                    preservationCapability:
                        revalidatedMediaPreservation,
                    preserveAudio: output.preserveAudio
                ) {
            throw containerError
        }
        let videoTimeRange = try await videoTrack.load(.timeRange)
        try AVFoundationSourceTimelinePreflight.validate(
            videoTimeRange,
            mediaType: .video
        )
        let naturalVideoTimeScale = try await videoTrack.load(.naturalTimeScale)
        let videoTimeScale = try ExactVideoWriterTimeScale.resolve(
            naturalTimeScale: naturalVideoTimeScale,
            trackTimeRange: videoTimeRange
        )
        let audioTracks: [AVAssetTrack]
        if output.preserveAudio {
            audioTracks = try await asset.loadTracks(
                withMediaType: .audio
            )
            guard audioTracks.count == source.audioTrackCount else {
                throw MediaPipelineError.metadataPreservationFailed(
                    "the source audio-track count changed after probing "
                        + "(expected \(source.audioTrackCount), observed "
                        + "\(audioTracks.count))"
                )
            }
        } else {
            audioTracks = []
        }
        for audioTrack in audioTracks {
            let audioTimeRange = try await audioTrack.load(
                .timeRange
            )
            try AVFoundationSourceTimelinePreflight.validate(
                audioTimeRange,
                mediaType: .audio
            )
        }
        let expectedCompressedAACTrackIdentities:
            [OutputMediaAACTrackIdentity]
        if output.preserveAudio {
            do {
                var identities: [OutputMediaAACTrackIdentity] = []
                identities.reserveCapacity(audioTracks.count)
                for (ordinal, audioTrack) in
                    audioTracks.enumerated() {
                    let formats = try await audioTrack.load(
                        .formatDescriptions
                    )
                    let subtypes = formats.map {
                        CMFormatDescriptionGetMediaSubType($0)
                    }
                    guard !subtypes.isEmpty else {
                        throw OutputMediaVerificationError
                            .compressedAACMismatch(
                                reason: "audio track \(ordinal + 1) "
                                    + "has no format description"
                            )
                    }
                    if subtypes.allSatisfy({
                        $0 == kAudioFormatMPEG4AAC
                    }) {
                        identities.append(
                            try await OutputMediaAACIdentityReader
                            .readTrack(
                                asset: asset,
                                track: audioTrack,
                                ordinal: ordinal,
                                cancellationCheck: {
                                    try Task.checkCancellation()
                                }
                            )
                        )
                    } else if subtypes.allSatisfy({
                        $0 == kAudioFormatLinearPCM
                    }) || subtypes.allSatisfy({
                        $0 == kAudioFormatAppleLossless
                    }) {
                        continue
                    } else {
                        throw OutputMediaVerificationError
                            .compressedAACMismatch(
                                reason: "audio track \(ordinal + 1) "
                                    + "is not uniformly AAC, Apple "
                                    + "Lossless, or Linear PCM"
                            )
                    }
                }
                expectedCompressedAACTrackIdentities =
                    output.preserveMetadata
                        ? identities
                        : identities.map {
                            OutputMediaAACTrackIdentity(
                                reference: $0.reference,
                                compressedIdentity:
                                    $0.compressedIdentity,
                                isEnabled: $0.isEnabled,
                                languageCode: $0.languageCode,
                                extendedLanguageTag:
                                    $0.extendedLanguageTag,
                                metadata:
                                    OutputMediaMetadataIdentity(
                                        canonicalItems: []
                                    )
                            )
                        }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MediaPipelineError.unsupportedAudioFormat(
                    String(describing: error)
                )
            }
        } else {
            expectedCompressedAACTrackIdentities = []
        }
        let subtitleTracks = try await Self.loadTracks(
            from: asset,
            mediaTypes: [.subtitle, .text, .closedCaption]
        )
        guard subtitleTracks.count == source.subtitleTrackCount else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the source subtitle-track count changed after probing "
                    + "(expected \(source.subtitleTrackCount), observed "
                    + "\(subtitleTracks.count))"
            )
        }
        let metadataTracks = try await Self.loadTracks(
            from: asset,
            mediaTypes: [.metadata, .timecode]
        )
        guard metadataTracks.count == source.metadataTrackCount else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the source metadata/timecode-track count changed after "
                    + "probing (expected \(source.metadataTrackCount), "
                    + "observed \(metadataTracks.count))"
            )
        }
        let containerMetadata = try await asset.load(.metadata)
        guard !containerMetadata.isEmpty == source.hasContainerMetadata else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the source container-metadata presence changed after probing"
            )
        }
        let selectedTracks = [videoTrack]
            + audioTracks
            + (output.preserveSubtitles ? subtitleTracks : [])
            + (output.preserveMetadata ? metadataTracks : [])
        let sourceMediaPreservation: SourceMediaPreservationPlan
        do {
            sourceMediaPreservation =
                try await SourceMediaPreservationPlanner.make(
                    asset: asset,
                    selectedTracks: selectedTracks,
                    preserveMetadata: output.preserveMetadata,
                    associationTargetSelection:
                        SourceMediaAssociationTargetSelection(
                            preserveAudio: output.preserveAudio,
                            preserveSubtitles:
                                output.preserveSubtitles,
                            preserveMetadata:
                                output.preserveMetadata
                        )
                )
        } catch let error as MediaPreservationIdentityError {
            switch error {
            case .missingAssociationTarget(
                let associationType,
                let sourceMediaType,
                let targetMediaType
            ):
                throw MediaPipelineError.unsupportedTrackAssociation(
                    associationType: associationType,
                    sourceMediaType: sourceMediaType,
                    targetMediaType: targetMediaType
                )
            case .disabledAssociationTarget:
                throw MediaPipelineError
                    .mediaPreservationPreflightFailed(
                        error.description
                    )
            default:
                throw MediaPipelineError.metadataPreservationFailed(
                    error.description
                )
            }
        } catch {
            throw MediaPipelineError.metadataPreservationFailed(
                String(describing: error)
            )
        }

        return try AVFoundationMediaSession(
            metal: metal,
            telemetry: telemetry,
            outputVerifier: outputVerifier,
            source: source,
            output: output,
            asset: asset,
            videoTrack: videoTrack,
            videoFormat: videoFormat,
            sourceVideoEndTime: CMTimeRangeGetEnd(videoTimeRange),
            videoTimeScale: videoTimeScale,
            videoTransform: videoTransform,
            audioTracks: audioTracks,
            expectedCompressedAACTrackIdentities:
                expectedCompressedAACTrackIdentities,
            sourceMediaPreservation: sourceMediaPreservation
        )
    }

    private static func loadTracks(
        from asset: AVURLAsset,
        mediaTypes: [AVMediaType]
    ) async throws -> [AVAssetTrack] {
        var result: [AVAssetTrack] = []
        for mediaType in mediaTypes {
            result.append(
                contentsOf: try await asset.loadTracks(
                    withMediaType: mediaType
                )
            )
        }
        return result
    }

    private init(
        metal: MetalRenderingService,
        telemetry: any ASHTelemetryRecording,
        outputVerifier: any OutputMediaVerifying,
        source: SourceProfile,
        output: OutputProfile,
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        videoFormat: MediaVideoFormat,
        sourceVideoEndTime: CMTime,
        videoTimeScale: CMTimeScale,
        videoTransform: CGAffineTransform,
        audioTracks: [AVAssetTrack],
        expectedCompressedAACTrackIdentities:
            [OutputMediaAACTrackIdentity],
        sourceMediaPreservation: SourceMediaPreservationPlan
    ) throws {
        guard !FileURLIdentity.refersToSameFile(source.url, output.url) else {
            throw MediaPipelineError.inputOutputCollision(source.url)
        }
        let deinterlacer: R13FormatPreservingDeinterlacer?
        if source.scanStructure.requiresDeinterlacing {
            do {
                deinterlacer = try R13FormatPreservingDeinterlacer(
                    resolution: source.codedResolution,
                    pixelFormat: videoFormat.pixelStorage.pixelFormat
                )
            } catch {
                throw MediaPipelineError.deinterlacingFailed(
                    String(describing: error)
                )
            }
        } else {
            deinterlacer = nil
        }

        let reader = try Self.makeReader(asset: asset, sourceURL: source.url)
        let readerOutputs = try Self.configureReaderOutputs(
            reader: reader,
            videoTrack: videoTrack,
            videoFormat: videoFormat
        )
        let outputTransaction = try Self.makeOutputTransaction(
            outputURL: output.url,
            transactionIdentifier: output.transactionIdentifier
        )
        outputTransaction.attachTelemetry(telemetry)
        let stagingFile = try Self.makeStagingFile(
            outputTransaction: outputTransaction,
            outputURL: output.url,
            videoFormat: videoFormat
        )
        let writer = try Self.makeWriter(
            outputTransaction: outputTransaction,
            stagingFile: stagingFile,
            outputURL: output.url,
            videoFormat: videoFormat
        )
        let writerInputs = try Self.configureWriterInputs(
            writer: writer,
            output: output,
            videoFormat: videoFormat,
            sourceResolution: source.resolution,
            videoTimeScale: videoTimeScale,
            videoTransform: videoTransform
        )
        let outputPixelBufferPool = try PixelBufferBridge.makePool(
            width: output.resolution.width,
            height: output.resolution.height,
            format: videoFormat.pixelStorage.pixelFormat,
            capacity: 8
        )
        try Self.start(
            reader: reader,
            writer: writer,
            outputTransaction: outputTransaction,
            stagingFile: stagingFile
        )
        writer.startSession(atSourceTime: .zero)

        self.sourceProfile = source
        self.outputProfile = output
        self.videoFormat = videoFormat
        self.outputPixelBufferPool = outputPixelBufferPool
        self.deinterlacer = deinterlacer
        self.asset = asset
        self.sourceVideoEndTime = sourceVideoEndTime
        self.reader = reader
        self.videoOutput = readerOutputs.video
        self.sourceAudioTracks = audioTracks
        self.writer = writer
        self.videoInput = writerInputs.video
        self.timedMetadataWriter = writerInputs.timedMetadata
        self.outputTransaction = outputTransaction
        self.stagingFile = stagingFile
        self.outputVerifier = outputVerifier
        self.telemetry = telemetry
        self.expectedCompressedAACTrackIdentities =
            expectedCompressedAACTrackIdentities
        self.expectedVideoTransform = writerInputs.videoTransform
        self.sourceMediaPreservation = sourceMediaPreservation
        telemetry.recordMedia(ASHMediaObservation(
            kind: "reader_writer_started",
            details: [
                "input_pixel_format":
                    AVFoundationMediaPipeline.fourCCString(
                        videoFormat.pixelStorage.pixelFormat
                    ),
                "output_pixel_format":
                    AVFoundationMediaPipeline.fourCCString(
                        videoFormat.pixelStorage.pixelFormat
                    ),
                "video_format": videoFormat.description,
                "source_scan_structure":
                    source.scanStructure.rawValue,
                "deinterlacing_algorithm":
                    deinterlacer == nil
                        ? "not_required"
                        : R13FormatPreservingDeinterlacer
                            .algorithmIdentity,
                "preserved_audio_track_count":
                    String(audioTracks.count),
                "preserved_subtitle_track_count":
                    String(source.subtitleTrackCount),
                "preserved_metadata_track_count":
                    String(source.metadataTrackCount),
                "output_dimensions": "\(output.resolution.width)x\(output.resolution.height)"
            ]
        ))
    }

    func nextSourceFrame() async throws -> FrameRecord? {
        let stage = telemetry.beginStage(.frameRead, frameIndex: frameIndex)
        defer { telemetry.endStage(stage) }
        try Task.checkCancellation()
        if sessionIsCancelled() { return nil }
        let currentSample: CMSampleBuffer
        if let pendingVideoSample {
            currentSample = pendingVideoSample
        } else if let firstSample = try copyNextVideoImageSample() {
            currentSample = firstSample
        } else {
            return nil
        }
        let nextSample = try copyNextVideoImageSample()
        pendingVideoSample = nextSample

        guard let buffer = CMSampleBufferGetImageBuffer(currentSample) else {
            throw failureAfterCleanup(
                MediaPipelineError.readerFailed(reader.error)
            )
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(currentSample)
        let nextPTS = nextSample.map(CMSampleBufferGetPresentationTimeStamp)
        let duration = FrameTiming.resolveDuration(
            sampleDuration: CMSampleBufferGetDuration(currentSample),
            presentationTime: pts,
            nextPresentationTime: nextPTS,
            timelineEnd: sourceVideoEndTime
        )
        let timing = FrameTiming(
            frameIndex: frameIndex,
            presentationTime: pts,
            duration: duration
        )
        let progressiveBuffer: CVPixelBuffer
        if let deinterlacer {
            do {
                progressiveBuffer = try deinterlacer
                    .makeProgressiveFrame(from: buffer)
            } catch {
                throw failureAfterCleanup(
                    MediaPipelineError.deinterlacingFailed(
                        String(describing: error)
                    )
                )
            }
        } else {
            progressiveBuffer = buffer
        }
        let record = FrameRecord(
            pixelBuffer: progressiveBuffer,
            timing: timing
        )
        telemetry.recordMedia(ASHMediaObservation(
            kind: "frame_read",
            frameIndex: frameIndex,
            presentationTimestampValue: pts.value,
            presentationTimestampTimescale: pts.timescale,
            details: [
                "pixel_format":
                    String(
                        CVPixelBufferGetPixelFormatType(
                            progressiveBuffer
                        )
                    ),
                "plane_count":
                    String(
                        CVPixelBufferGetPlaneCount(
                            progressiveBuffer
                        )
                    ),
                "source_scan_structure":
                    sourceProfile.scanStructure.rawValue,
                "deinterlacing_algorithm":
                    deinterlacer == nil
                        ? "not_required"
                        : R13FormatPreservingDeinterlacer
                            .algorithmIdentity,
                "duration_value": String(duration.value),
                "duration_timescale": String(duration.timescale)
            ]
        ))
        frameIndex += 1
        return record
    }

    private func copyNextVideoImageSample() throws -> CMSampleBuffer? {
        while let sample = videoOutput.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { return sample }
        }
        if let error = reader.error {
            throw failureAfterCleanup(MediaPipelineError.readerFailed(error))
        }
        return nil
    }

    func appendOutput(pixelBuffer: CVPixelBuffer, timing: FrameTiming) async throws {
        let backpressure = telemetry.beginStage(.writerBackpressure)
        do {
            while !videoInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if sessionIsCancelled() { throw CancellationError() }
                guard writer.status == .writing else {
                    throw MediaPipelineError.writerFailed(writer.error)
                }
                if !videoInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
        } catch {
            telemetry.endStage(backpressure)
            if error is CancellationError { throw error }
            throw failureAfterCleanup(error)
        }
        telemetry.endStage(backpressure)
        let append = telemetry.beginStage(.writerAppend)
        defer { telemetry.endStage(append) }
        try Task.checkCancellation()
        if sessionIsCancelled() { throw CancellationError() }
        do {
            try timingLock.withLock {
                try timingLedger.append(timing) {
                    try videoFormat.validate(pixelBuffer: pixelBuffer)
                    videoFormat.installAttachments(on: pixelBuffer)
                    let sampleBuffer = try Self.makeVideoSampleBuffer(
                        pixelBuffer: pixelBuffer,
                        timing: timing
                    )
                    guard videoInput.append(sampleBuffer) else {
                        throw MediaPipelineError.writerFailed(writer.error)
                    }
                }
            }
        } catch let error as FrameTimingLedgerError {
            throw failureAfterCleanup(
                MediaPipelineError.invalidFrameTiming(String(describing: error))
            )
        } catch {
            throw failureAfterCleanup(error)
        }
        telemetry.recordMedia(ASHMediaObservation(
            kind: "frame_appended",
            frameIndex: timing.frameIndex,
            presentationTimestampValue: timing.presentationTime.value,
            presentationTimestampTimescale: timing.presentationTime.timescale,
            details: [
                "duration_value": String(timing.duration.value),
                "duration_timescale": String(timing.duration.timescale)
            ]
        ))
    }

    deinit {
        if let error = stagingFile.cleanup() {
            retainStagingCleanupError(error)
        }
        let cleanup = outputTransaction.fail()
        retainCleanupError(cleanup)
    }
}
