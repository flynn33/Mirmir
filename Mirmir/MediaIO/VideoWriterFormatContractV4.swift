import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum VideoWriterCodecV4: String, CaseIterable, Hashable, Sendable {
    case h264
    case hevc
    case proRes422

    var avVideoCodecType: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .proRes422: .proRes422
        }
    }

    var encodedMediaSubtype: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        case .proRes422: kCMVideoCodecType_AppleProRes422
        }
    }
}

/// Describes every operation that may affect the relationship between an HDR
/// presentation sample and its frame-bound dynamic metadata.
enum VideoWriterFrameOperationV4: String, Hashable, Sendable {
    case unmodified
    case spatialResampling
    case temporalSynthesis
    case frameRateConversion
    /// Deterministic two-field normalization: each source presentation sample
    /// is divided into two progressive samples covering the same interval.
    case fieldNormalization
    case toneMapping
    case transferFunctionConversion

    var pixelsWereModified: Bool {
        self != .unmodified
    }
}

enum VideoWriterColorContractV4: Hashable, Sendable {
    case sdrBT709
    case sdr(primaries: String, transferFunction: String, matrix: String)
    case hdr(HDRFormatMetadataV4)
}

enum VideoWriterFormatContractV4Error: Error, Equatable, Sendable {
    case nonPositiveOutputDimensions(width: Int, height: Int)
    case outputDimensionsExceedEngineLimit(width: Int, height: Int, limit: Int)
    case subsampledDimensionsMustBeEven(width: Int, height: Int)
    case incompatibleCodecAndStorage(
        codec: VideoWriterCodecV4,
        storage: PixelStorageV4
    )
    case hdrRequiresP010(storage: PixelStorageV4)
    case hdrStorageMismatch(expected: PixelStorageV4, actual: PixelStorageV4)
    case hdrRequiresHEVC(codec: VideoWriterCodecV4)
    case hdrOperationWouldChangeTransfer(VideoWriterFrameOperationV4)
    case dynamicHDRPreservationRequired
    case dynamicHDRPolicyWithoutSourceMetadata
    case dynamicHDRIncompatibleOperation(VideoWriterFrameOperationV4)
    case nonIntegralOutputTransformTranslation(
        x: ExactRationalV4,
        y: ExactRationalV4
    )
    case cleanApertureCannotBeRepresentedExactly(
        field: String,
        value: ExactRationalV4
    )
    case pixelAspectRatioExceedsContainerLimit(
        horizontalSpacing: Int64,
        verticalSpacing: Int64
    )
    case writerRejectedOutputSettings(codec: VideoWriterCodecV4)
    case writerRejectedInput(codec: VideoWriterCodecV4)
    case encodedMediaTypeMismatch(actual: CMMediaType)
    case encodedCodecMismatch(expected: CMVideoCodecType, actual: CMVideoCodecType)
    case encodedDimensionMismatch(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int32,
        actualHeight: Int32
    )
    case encodedGeometryMissing(field: String)
    case encodedGeometryMismatch(
        field: String,
        expected: String,
        actual: String
    )
    case encodedColorMismatch(
        field: String,
        expected: String,
        actual: String?
    )
    case encodedBitDepthMismatch(expected: Int, actual: Int)
    case encodedRangeMismatch(expected: PixelCodeRangeV4, actualFullRange: Bool?)
    case encodedHDRMetadataMismatch
    case decodedStorageMismatch(expected: PixelStorageV4, actual: PixelStorageV4)
    case unsupportedDecodedPixelFormat(OSType)
    case decodedHDRMetadataMismatch
    case dynamicHDRMetadataMismatch
    case malformedFormatDescription(field: String)
}

/// Exact geometry after the deterministic scaler has produced the requested
/// coded raster. SAR compensates for unequal X/Y scale, clean aperture is
/// rescaled in coded-pixel space, and the display transform is conjugated by
/// the axis scales. No geometry passes through floating point until the final
/// AVFoundation bridge, where exact binary representability is required.
struct VideoWriterOutputGeometryV4: Equatable, Hashable, Sendable {
    let codedWidth: Int
    let codedHeight: Int
    let cleanAperture: CleanApertureV4
    let sampleAspectRatio: SampleAspectRatioV4
    let preferredTransform: RationalAffineTransformV4
    let outputScaleX: ExactRationalV4
    let outputScaleY: ExactRationalV4

    init(
        source: RationalPresentationGeometryV4,
        codedWidth: Int,
        codedHeight: Int
    ) throws {
        guard codedWidth > 0, codedHeight > 0 else {
            throw VideoWriterFormatContractV4Error.nonPositiveOutputDimensions(
                width: codedWidth,
                height: codedHeight
            )
        }
        let limit = SpatialAxisScalePlanV4.maximumSupportedExtent
        guard codedWidth <= limit, codedHeight <= limit else {
            throw VideoWriterFormatContractV4Error
                .outputDimensionsExceedEngineLimit(
                    width: codedWidth,
                    height: codedHeight,
                    limit: limit
                )
        }

        let outputScaleX = try ExactRationalV4(
            Int64(codedWidth),
            source.codedWidth
        )
        let outputScaleY = try ExactRationalV4(
            Int64(codedHeight),
            source.codedHeight
        )
        let outputAperture = try CleanApertureV4(
            width: source.cleanAperture.width.multiplied(by: outputScaleX),
            height: source.cleanAperture.height.multiplied(by: outputScaleY),
            horizontalOffset: source.cleanAperture.horizontalOffset
                .multiplied(by: outputScaleX),
            verticalOffset: source.cleanAperture.verticalOffset
                .multiplied(by: outputScaleY)
        )

        // Each output sample represents 1/scale of a source sample. Correcting
        // both axes therefore changes PAR by scaleY/scaleX.
        let outputSAR = try source.sampleAspectRatio.horizontalScale
            .multiplied(by: outputScaleY)
            .divided(by: outputScaleX)
        guard outputSAR.numerator <= Int64(Int32.max),
              outputSAR.denominator <= Int64(Int32.max) else {
            throw VideoWriterFormatContractV4Error
                .pixelAspectRatioExceedsContainerLimit(
                    horizontalSpacing: outputSAR.numerator,
                    verticalSpacing: outputSAR.denominator
                )
        }
        let outputSampleAspectRatio = try SampleAspectRatioV4(
            horizontalSpacing: outputSAR.numerator,
            verticalSpacing: outputSAR.denominator
        )

        // The compensating output SAR makes the pre-orientation presentation
        // coordinates a uniform scaleY multiple of the source presentation:
        // diag(sourcePAR * scaleY/scaleX, 1) * diag(scaleX, scaleY)
        // == scaleY * diag(sourcePAR, 1). The preferred transform's linear
        // part is therefore unchanged and both translations scale by scaleY.
        let outputTransform = RationalAffineTransformV4(
            a: source.preferredTransform.a,
            b: source.preferredTransform.b,
            c: source.preferredTransform.c,
            d: source.preferredTransform.d,
            tx: try source.preferredTransform.tx.multiplied(
                by: outputScaleY
            ),
            ty: try source.preferredTransform.ty.multiplied(
                by: outputScaleY
            )
        )
        guard outputTransform.tx.isInteger, outputTransform.ty.isInteger else {
            throw VideoWriterFormatContractV4Error
                .nonIntegralOutputTransformTranslation(
                    x: outputTransform.tx,
                    y: outputTransform.ty
                )
        }

        // Re-run the complete exact geometry invariant set on the transformed
        // output before exposing it to AVFoundation.
        _ = try RationalPresentationGeometryV4(
            codedWidth: Int64(codedWidth),
            codedHeight: Int64(codedHeight),
            cleanAperture: outputAperture,
            sampleAspectRatio: outputSampleAspectRatio,
            preferredTransform: outputTransform
        )

        self.codedWidth = codedWidth
        self.codedHeight = codedHeight
        self.cleanAperture = outputAperture
        self.sampleAspectRatio = outputSampleAspectRatio
        self.preferredTransform = outputTransform
        self.outputScaleX = outputScaleX
        self.outputScaleY = outputScaleY
    }

    var rationalGeometry: RationalPresentationGeometryV4 {
        // Construction already validated this exact value.
        try! RationalPresentationGeometryV4(
            codedWidth: Int64(codedWidth),
            codedHeight: Int64(codedHeight),
            cleanAperture: cleanAperture,
            sampleAspectRatio: sampleAspectRatio,
            preferredTransform: preferredTransform
        )
    }

    var avPreferredTransform: CGAffineTransform {
        CGAffineTransform(
            a: CGFloat(preferredTransform.a.integerValue!),
            b: CGFloat(preferredTransform.b.integerValue!),
            c: CGFloat(preferredTransform.c.integerValue!),
            d: CGFloat(preferredTransform.d.integerValue!),
            tx: CGFloat(preferredTransform.tx.integerValue!),
            ty: CGFloat(preferredTransform.ty.integerValue!)
        )
    }
}

struct VideoWriterEndpointV4 {
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
}

/// Fail-closed bridge from deterministic V4 media semantics to AVAssetWriter.
/// It performs no scaling, color conversion, tone mapping, or bit-depth
/// conversion. The caller must append buffers that exactly match
/// `sourcePixelBufferAttributes` and must execute the reopen checks.
struct VideoWriterFormatContractV4: Hashable, Sendable {
    let codec: VideoWriterCodecV4
    let storage: PixelStorageV4
    let color: VideoWriterColorContractV4
    let geometry: VideoWriterOutputGeometryV4
    let frameOperation: VideoWriterFrameOperationV4
    let sourceContainsDynamicHDRMetadata: Bool
    let dynamicEncodingPolicy: HDRDynamicEncodingPolicyV4

    init(
        codec: VideoWriterCodecV4,
        storage: PixelStorageV4,
        color: VideoWriterColorContractV4,
        sourceGeometry: RationalPresentationGeometryV4,
        outputWidth: Int,
        outputHeight: Int,
        frameOperation: VideoWriterFrameOperationV4,
        sourceContainsDynamicHDRMetadata: Bool = false,
        dynamicEncodingPolicy: HDRDynamicEncodingPolicyV4 = .absent
    ) throws {
        guard outputWidth > 0, outputHeight > 0 else {
            throw VideoWriterFormatContractV4Error.nonPositiveOutputDimensions(
                width: outputWidth,
                height: outputHeight
            )
        }
        let limit = SpatialAxisScalePlanV4.maximumSupportedExtent
        guard outputWidth <= limit, outputHeight <= limit else {
            throw VideoWriterFormatContractV4Error
                .outputDimensionsExceedEngineLimit(
                    width: outputWidth,
                    height: outputHeight,
                    limit: limit
                )
        }
        guard outputWidth.isMultiple(of: 2), outputHeight.isMultiple(of: 2) else {
            throw VideoWriterFormatContractV4Error
                .subsampledDimensionsMustBeEven(
                    width: outputWidth,
                    height: outputHeight
                )
        }
        if storage.signalBitDepth == 10,
           codec != .hevc,
           codec != .proRes422 {
            throw VideoWriterFormatContractV4Error
                .incompatibleCodecAndStorage(codec: codec, storage: storage)
        }
        // The deterministic opaque engine currently emits bi-planar 4:2:0
        // buffers. Apple ProRes 422 is a video-range delivery codec, and the
        // calibrated bridge is intentionally limited to video-range NV12 and
        // P010 input. Admit full-range storage only after it has its own exact
        // range qualification contract.
        if codec == .proRes422,
           storage != .nv12VideoRange8Bit,
           storage != .p010VideoRange10Bit {
            throw VideoWriterFormatContractV4Error
                .incompatibleCodecAndStorage(codec: codec, storage: storage)
        }

        switch color {
        case .sdrBT709, .sdr:
            if sourceContainsDynamicHDRMetadata {
                throw VideoWriterFormatContractV4Error
                    .dynamicHDRPreservationRequired
            }
            guard dynamicEncodingPolicy == .absent else {
                throw VideoWriterFormatContractV4Error
                    .dynamicHDRPolicyWithoutSourceMetadata
            }
        case .hdr(let metadata):
            guard storage == .p010VideoRange10Bit
                    || storage == .p010FullRange10Bit else {
                throw VideoWriterFormatContractV4Error
                    .hdrRequiresP010(storage: storage)
            }
            guard metadata.signal.storage == storage else {
                throw VideoWriterFormatContractV4Error.hdrStorageMismatch(
                    expected: storage,
                    actual: metadata.signal.storage
                )
            }
            guard codec == .hevc else {
                throw VideoWriterFormatContractV4Error
                    .hdrRequiresHEVC(codec: codec)
            }
            guard frameOperation != .toneMapping,
                  frameOperation != .transferFunctionConversion else {
                throw VideoWriterFormatContractV4Error
                    .hdrOperationWouldChangeTransfer(frameOperation)
            }
            if sourceContainsDynamicHDRMetadata {
                guard dynamicEncodingPolicy != .absent else {
                    throw VideoWriterFormatContractV4Error
                        .dynamicHDRPreservationRequired
                }
                switch (dynamicEncodingPolicy, frameOperation) {
                case (.preserveSourceWhenPixelsAreUnmodified, .unmodified),
                     (
                        .preserveSourceSceneMetadataAcrossSpatialResampling,
                        .spatialResampling
                     ),
                     (
                        .replicateSourceSceneMetadataAcrossFieldNormalization,
                        .fieldNormalization
                     ):
                    break
                default:
                    throw VideoWriterFormatContractV4Error
                        .dynamicHDRIncompatibleOperation(frameOperation)
                }
            } else if dynamicEncodingPolicy != .absent {
                throw VideoWriterFormatContractV4Error
                    .dynamicHDRPolicyWithoutSourceMetadata
            }
        }

        self.codec = codec
        self.storage = storage
        self.color = color
        self.geometry = try VideoWriterOutputGeometryV4(
            source: sourceGeometry,
            codedWidth: outputWidth,
            codedHeight: outputHeight
        )
        self.frameOperation = frameOperation
        self.sourceContainsDynamicHDRMetadata =
            sourceContainsDynamicHDRMetadata
        self.dynamicEncodingPolicy = dynamicEncodingPolicy

        // AVVideoCleanAperture accepts floating-point NSNumbers. Refuse every
        // exact rational that cannot survive that bridge bit-for-bit.
        _ = try cleanApertureSettings
    }

    var outputSettings: [String: Any] {
        get throws {
            var compression: [String: Any] = [
                kVTCompressionPropertyKey_FieldCount as String:
                    NSNumber(value: 1)
            ]
            if let profileLevel {
                compression[AVVideoProfileLevelKey] = profileLevel
            }
            if codec == .h264 {
                // Automatic B-frame decisions vary with buffer arrival pacing,
                // producing different decoded pixels from identical inputs.
                compression[AVVideoAllowFrameReorderingKey] = false
            }
            if case .hdr(let metadata) = color {
                compression.merge(
                    try AVFoundationHDRMetadataAdapterV4
                        .videoToolboxCompressionProperties(
                            for: metadata,
                            dynamicPolicy: dynamicEncodingPolicy,
                            pixelsWereModified: frameOperation.pixelsWereModified
                        ),
                    uniquingKeysWith: { _, new in new }
                )
            }

            let settings: [String: Any] = [
                AVVideoCodecKey: codec.avVideoCodecType,
                AVVideoWidthKey: NSNumber(value: geometry.codedWidth),
                AVVideoHeightKey: NSNumber(value: geometry.codedHeight),
                AVVideoPixelAspectRatioKey: pixelAspectRatioSettings,
                AVVideoCleanApertureKey: try cleanApertureSettings,
                AVVideoColorPropertiesKey: colorProperties,
                AVVideoCompressionPropertiesKey: compression
            ]
            return settings
        }
    }

    var sourcePixelBufferAttributes: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: storage.pixelFormat),
            kCVPixelBufferWidthKey as String:
                NSNumber(value: geometry.codedWidth),
            kCVPixelBufferHeightKey as String:
                NSNumber(value: geometry.codedHeight),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
    }

    /// Exact expected extensions are useful for source hints, deterministic
    /// fixtures, and post-encode semantic comparison. Rational clean-aperture
    /// keys are included in addition to their required floating-point mirrors.
    var expectedFormatDescriptionExtensions: [CFString: Any] {
        get throws {
            var extensions: [CFString: Any] = [
                kCMFormatDescriptionExtension_CleanAperture:
                    try coreMediaCleanAperture,
                kCMFormatDescriptionExtension_PixelAspectRatio: [
                    kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing:
                        NSNumber(
                            value: geometry.sampleAspectRatio.horizontalSpacing
                        ),
                    kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing:
                        NSNumber(
                            value: geometry.sampleAspectRatio.verticalSpacing
                        )
                ],
                kCMFormatDescriptionExtension_FieldCount: NSNumber(value: 1),
                kCMFormatDescriptionExtension_FullRangeVideo:
                    NSNumber(value: storage.codeRange == .full),
                kCMFormatDescriptionExtension_BitsPerComponent:
                    NSNumber(value: expectedFormatDescriptionBitDepth)
            ]
            switch color {
            case .sdrBT709, .sdr:
                extensions[kCMFormatDescriptionExtension_ColorPrimaries] =
                    colorProperties[AVVideoColorPrimariesKey]
                extensions[kCMFormatDescriptionExtension_TransferFunction] =
                    colorProperties[AVVideoTransferFunctionKey]
                extensions[kCMFormatDescriptionExtension_YCbCrMatrix] =
                    colorProperties[AVVideoYCbCrMatrixKey]
            case .hdr(let metadata):
                extensions.merge(
                    AVFoundationHDRMetadataAdapterV4
                        .formatDescriptionExtensions(for: metadata),
                    uniquingKeysWith: { _, new in new }
                )
            }
            return extensions
        }
    }

    func makeExpectedFormatDescription() throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec.encodedMediaSubtype,
            width: Int32(geometry.codedWidth),
            height: Int32(geometry.codedHeight),
            extensions: try expectedFormatDescriptionExtensions as CFDictionary,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw VideoWriterFormatContractV4Error.malformedFormatDescription(
                field: "creation_status_\(status)"
            )
        }
        return description
    }

    func preflight(writer: AVAssetWriter) throws {
        let settings = try outputSettings
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw VideoWriterFormatContractV4Error
                .writerRejectedOutputSettings(codec: codec)
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings
        )
        input.transform = geometry.avPreferredTransform
        guard writer.canAdd(input) else {
            throw VideoWriterFormatContractV4Error
                .writerRejectedInput(codec: codec)
        }
    }

    func makeEndpoint(writer: AVAssetWriter) throws -> VideoWriterEndpointV4 {
        let settings = try outputSettings
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw VideoWriterFormatContractV4Error
                .writerRejectedOutputSettings(codec: codec)
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings
        )
        input.transform = geometry.avPreferredTransform
        guard writer.canAdd(input) else {
            throw VideoWriterFormatContractV4Error
                .writerRejectedInput(codec: codec)
        }
        writer.add(input)
        return VideoWriterEndpointV4(
            input: input,
            adaptor: AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )
        )
    }

    func verifyReopenedFormat(
        _ formatDescription: CMFormatDescription,
        preferredTransform: CGAffineTransform
    ) throws {
        let mediaType = CMFormatDescriptionGetMediaType(formatDescription)
        guard mediaType == kCMMediaType_Video else {
            throw VideoWriterFormatContractV4Error
                .encodedMediaTypeMismatch(actual: mediaType)
        }
        let subtype = CMFormatDescriptionGetMediaSubType(formatDescription)
        guard subtype == codec.encodedMediaSubtype else {
            throw VideoWriterFormatContractV4Error.encodedCodecMismatch(
                expected: codec.encodedMediaSubtype,
                actual: subtype
            )
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        guard dimensions.width == Int32(geometry.codedWidth),
              dimensions.height == Int32(geometry.codedHeight) else {
            throw VideoWriterFormatContractV4Error.encodedDimensionMismatch(
                expectedWidth: geometry.codedWidth,
                expectedHeight: geometry.codedHeight,
                actualWidth: dimensions.width,
                actualHeight: dimensions.height
            )
        }
        try verifyPreferredTransform(preferredTransform)

        let extensions = (
            CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary?
        ) ?? [:]
        try verifyCleanAperture(extensions)
        try verifyPixelAspectRatio(extensions)
        try verifyRangeAndBitDepth(extensions)
        try verifyColor(extensions, formatDescription: formatDescription)
    }

    func verifyDecodedPixelBuffer(_ pixelBuffer: CVPixelBuffer) throws {
        let actualStorage: PixelStorageV4
        do {
            actualStorage = try PixelStorageV4(
                pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer)
            )
        } catch {
            throw VideoWriterFormatContractV4Error.unsupportedDecodedPixelFormat(
                CVPixelBufferGetPixelFormatType(pixelBuffer)
            )
        }
        guard actualStorage == storage else {
            throw VideoWriterFormatContractV4Error.decodedStorageMismatch(
                expected: storage,
                actual: actualStorage
            )
        }
        try PixelLayoutV4(storage: storage).validateStructure(of: pixelBuffer)
        let observed = try AVFoundationHDRMetadataAdapterV4.probe(
            pixelBuffer: pixelBuffer,
            storage: storage
        )
        switch color {
        case .sdrBT709, .sdr:
            guard observed == nil else {
                throw VideoWriterFormatContractV4Error
                    .decodedHDRMetadataMismatch
            }
        case .hdr(let expected):
            guard observed == expected else {
                throw VideoWriterFormatContractV4Error
                    .decodedHDRMetadataMismatch
            }
        }
    }

    /// Dynamic HDR is frame-bound. Reopen validation therefore compares each
    /// encoded sample against the metadata observed on its exact source sample.
    func verifyDynamicHDRMetadata(
        in encodedSample: CMSampleBuffer,
        expectedSourceMetadata: HDRDynamicMetadataV4?
    ) throws {
        let actual = try AVFoundationHDRMetadataAdapterV4
            .probeDynamicMetadata(from: encodedSample)
        guard actual == expectedSourceMetadata else {
            throw VideoWriterFormatContractV4Error
                .dynamicHDRMetadataMismatch
        }
    }

    private var profileLevel: CFString? {
        switch (codec, storage.signalBitDepth) {
        case (.h264, _): kVTProfileLevel_H264_High_AutoLevel
        case (.hevc, 10): kVTProfileLevel_HEVC_Main10_AutoLevel
        case (.hevc, _): kVTProfileLevel_HEVC_Main_AutoLevel
        case (.proRes422, _): nil
        }
    }

    /// ProRes 422 always stores a 10-bit encoded Y'CbCr signal even when its
    /// deterministic writer input is the currently qualified 8-bit NV12
    /// route. Keep encoded precision distinct from the processing buffer.
    private var encodedSignalBitDepth: Int {
        switch codec {
        case .proRes422: 10
        case .h264, .hevc: storage.signalBitDepth
        }
    }

    /// Core Media describes Apple's `apcn` decoder surface as 12 bits per
    /// component even though ProRes 422 carries a 10-bit signal. Bind and
    /// verify the actual AVFoundation description separately from the logical
    /// encoded precision so a runtime that changes this behavior fails closed.
    private var expectedFormatDescriptionBitDepth: Int {
        switch codec {
        case .proRes422: 12
        case .h264, .hevc: encodedSignalBitDepth
        }
    }

    private var colorProperties: [String: String] {
        switch color {
        case .sdr(let primaries, let transfer, let matrix):
            [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix
            ]
        case .sdrBT709:
            [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey:
                    AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        case .hdr(let metadata):
            AVFoundationHDRMetadataAdapterV4.avFoundationColorProperties(
                for: metadata.signal
            )
        }
    }

    private var pixelAspectRatioSettings: [String: Any] {
        [
            AVVideoPixelAspectRatioHorizontalSpacingKey:
                NSNumber(value: geometry.sampleAspectRatio.horizontalSpacing),
            AVVideoPixelAspectRatioVerticalSpacingKey:
                NSNumber(value: geometry.sampleAspectRatio.verticalSpacing)
        ]
    }

    private var cleanApertureSettings: [String: Any] {
        get throws {
            [
                AVVideoCleanApertureWidthKey: try exactNSNumber(
                    geometry.cleanAperture.width,
                    field: "width"
                ),
                AVVideoCleanApertureHeightKey: try exactNSNumber(
                    geometry.cleanAperture.height,
                    field: "height"
                ),
                AVVideoCleanApertureHorizontalOffsetKey: try exactNSNumber(
                    geometry.cleanAperture.horizontalOffset,
                    field: "horizontal_offset"
                ),
                AVVideoCleanApertureVerticalOffsetKey: try exactNSNumber(
                    geometry.cleanAperture.verticalOffset,
                    field: "vertical_offset"
                )
            ]
        }
    }

    private var coreMediaCleanAperture: [CFString: Any] {
        get throws {
            let aperture = geometry.cleanAperture
            return [
                kCMFormatDescriptionKey_CleanApertureWidth:
                    try exactNSNumber(aperture.width, field: "width"),
                kCMFormatDescriptionKey_CleanApertureHeight:
                    try exactNSNumber(aperture.height, field: "height"),
                kCMFormatDescriptionKey_CleanApertureHorizontalOffset:
                    try exactNSNumber(
                        aperture.horizontalOffset,
                        field: "horizontal_offset"
                    ),
                kCMFormatDescriptionKey_CleanApertureVerticalOffset:
                    try exactNSNumber(
                        aperture.verticalOffset,
                        field: "vertical_offset"
                    ),
                kCMFormatDescriptionKey_CleanApertureWidthRational:
                    rationalArray(aperture.width),
                kCMFormatDescriptionKey_CleanApertureHeightRational:
                    rationalArray(aperture.height),
                kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational:
                    rationalArray(aperture.horizontalOffset),
                kCMFormatDescriptionKey_CleanApertureVerticalOffsetRational:
                    rationalArray(aperture.verticalOffset)
            ]
        }
    }

    private func exactNSNumber(
        _ value: ExactRationalV4,
        field: String
    ) throws -> NSNumber {
        let denominatorMagnitude = UInt64(value.denominator)
        let denominatorIsPowerOfTwo = denominatorMagnitude != 0
            && denominatorMagnitude & (denominatorMagnitude - 1) == 0
        let numeratorMagnitude = value.numerator.magnitude
        let significantBitCount: Int
        if numeratorMagnitude == 0 {
            significantBitCount = 0
        } else {
            significantBitCount = UInt64.bitWidth
                - numeratorMagnitude.leadingZeroBitCount
                - numeratorMagnitude.trailingZeroBitCount
        }
        guard denominatorIsPowerOfTwo, significantBitCount <= 53 else {
            throw VideoWriterFormatContractV4Error
                .cleanApertureCannotBeRepresentedExactly(
                    field: field,
                    value: value
                )
        }
        let doubleValue = Double(value.numerator) / Double(value.denominator)
        guard doubleValue.isFinite else {
            throw VideoWriterFormatContractV4Error
                .cleanApertureCannotBeRepresentedExactly(
                    field: field,
                    value: value
                )
        }
        return NSNumber(value: doubleValue)
    }

    private func rationalArray(_ value: ExactRationalV4) -> [NSNumber] {
        [NSNumber(value: value.numerator), NSNumber(value: value.denominator)]
    }

    private func verifyPreferredTransform(
        _ actual: CGAffineTransform
    ) throws {
        let expected = geometry.avPreferredTransform
        let expectedValues = [
            expected.a, expected.b, expected.c, expected.d, expected.tx,
            expected.ty
        ]
        let actualValues = [
            actual.a, actual.b, actual.c, actual.d, actual.tx, actual.ty
        ]
        guard expectedValues == actualValues else {
            throw VideoWriterFormatContractV4Error.encodedGeometryMismatch(
                field: "preferred_transform",
                expected: expectedValues.map(String.init(describing:)).joined(
                    separator: ","
                ),
                actual: actualValues.map(String.init(describing:)).joined(
                    separator: ","
                )
            )
        }
    }

    private func verifyCleanAperture(_ extensions: NSDictionary) throws {
        guard let actual = extensions[
            kCMFormatDescriptionExtension_CleanAperture as String
        ] as? NSDictionary else {
            throw VideoWriterFormatContractV4Error
                .encodedGeometryMissing(field: "clean_aperture")
        }
        try verifyRationalGeometryValue(
            actual,
            floatKey: kCMFormatDescriptionKey_CleanApertureWidth,
            rationalKey: kCMFormatDescriptionKey_CleanApertureWidthRational,
            expected: geometry.cleanAperture.width,
            field: "clean_aperture.width"
        )
        try verifyRationalGeometryValue(
            actual,
            floatKey: kCMFormatDescriptionKey_CleanApertureHeight,
            rationalKey: kCMFormatDescriptionKey_CleanApertureHeightRational,
            expected: geometry.cleanAperture.height,
            field: "clean_aperture.height"
        )
        try verifyRationalGeometryValue(
            actual,
            floatKey: kCMFormatDescriptionKey_CleanApertureHorizontalOffset,
            rationalKey:
                kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational,
            expected: geometry.cleanAperture.horizontalOffset,
            field: "clean_aperture.horizontal_offset"
        )
        try verifyRationalGeometryValue(
            actual,
            floatKey: kCMFormatDescriptionKey_CleanApertureVerticalOffset,
            rationalKey:
                kCMFormatDescriptionKey_CleanApertureVerticalOffsetRational,
            expected: geometry.cleanAperture.verticalOffset,
            field: "clean_aperture.vertical_offset"
        )
    }

    private func verifyRationalGeometryValue(
        _ dictionary: NSDictionary,
        floatKey: CFString,
        rationalKey: CFString,
        expected: ExactRationalV4,
        field: String
    ) throws {
        let expectedNumber = try exactNSNumber(expected, field: field)
        guard let actualNumber = dictionary[floatKey as String] as? NSNumber else {
            throw VideoWriterFormatContractV4Error
                .encodedGeometryMissing(field: field)
        }
        guard actualNumber.doubleValue == expectedNumber.doubleValue else {
            throw VideoWriterFormatContractV4Error.encodedGeometryMismatch(
                field: field,
                expected: expected.description,
                actual: String(actualNumber.doubleValue)
            )
        }
        if let rational = dictionary[rationalKey as String] as? [NSNumber] {
            guard rational.count == 2,
                  rational[0].int64Value == expected.numerator,
                  rational[1].int64Value == expected.denominator else {
                throw VideoWriterFormatContractV4Error
                    .encodedGeometryMismatch(
                        field: "\(field).rational",
                        expected: expected.description,
                        actual: rational.map(\.stringValue).joined(separator: "/")
                    )
            }
        }
    }

    private func verifyPixelAspectRatio(_ extensions: NSDictionary) throws {
        guard let actual = extensions[
            kCMFormatDescriptionExtension_PixelAspectRatio as String
        ] as? NSDictionary else {
            throw VideoWriterFormatContractV4Error
                .encodedGeometryMissing(field: "pixel_aspect_ratio")
        }
        let horizontal = (actual[
            kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String
        ] as? NSNumber)?.int64Value
        let vertical = (actual[
            kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String
        ] as? NSNumber)?.int64Value
        guard horizontal == geometry.sampleAspectRatio.horizontalSpacing,
              vertical == geometry.sampleAspectRatio.verticalSpacing else {
            throw VideoWriterFormatContractV4Error.encodedGeometryMismatch(
                field: "pixel_aspect_ratio",
                expected: "\(geometry.sampleAspectRatio.horizontalSpacing):"
                    + "\(geometry.sampleAspectRatio.verticalSpacing)",
                actual: "\(horizontal.map(String.init) ?? "missing"):"
                    + "\(vertical.map(String.init) ?? "missing")"
            )
        }
    }

    private func verifyRangeAndBitDepth(_ extensions: NSDictionary) throws {
        let fullRange = (extensions[
            kCMFormatDescriptionExtension_FullRangeVideo as String
        ] as? NSNumber)?.boolValue
        switch storage.codeRange {
        case .full:
            guard fullRange == true else {
                throw VideoWriterFormatContractV4Error.encodedRangeMismatch(
                    expected: .full,
                    actualFullRange: fullRange
                )
            }
        case .video:
            guard fullRange != true else {
                throw VideoWriterFormatContractV4Error.encodedRangeMismatch(
                    expected: .video,
                    actualFullRange: fullRange
                )
            }
        }
        if let bitDepth = (extensions[
            kCMFormatDescriptionExtension_BitsPerComponent as String
        ] as? NSNumber)?.intValue,
           bitDepth != expectedFormatDescriptionBitDepth {
            throw VideoWriterFormatContractV4Error.encodedBitDepthMismatch(
                expected: expectedFormatDescriptionBitDepth,
                actual: bitDepth
            )
        }
    }

    private func verifyColor(
        _ extensions: NSDictionary,
        formatDescription: CMFormatDescription
    ) throws {
        switch color {
        case .sdrBT709, .sdr:
            try verifyColorField(
                extensions,
                key: kCMFormatDescriptionExtension_ColorPrimaries,
                expected: colorProperties[AVVideoColorPrimariesKey]!,
                field: "color_primaries"
            )
            try verifyColorField(
                extensions,
                key: kCMFormatDescriptionExtension_TransferFunction,
                expected: colorProperties[AVVideoTransferFunctionKey]!,
                field: "transfer_function"
            )
            try verifyColorField(
                extensions,
                key: kCMFormatDescriptionExtension_YCbCrMatrix,
                expected: colorProperties[AVVideoYCbCrMatrixKey]!,
                field: "ycbcr_matrix"
            )
        case .hdr(let expected):
            let observed = try AVFoundationHDRMetadataAdapterV4.probe(
                formatDescription: formatDescription,
                decodedStorage: storage
            )
            guard observed == expected else {
                throw VideoWriterFormatContractV4Error
                    .encodedHDRMetadataMismatch
            }
        }
    }

    private func verifyColorField(
        _ extensions: NSDictionary,
        key: CFString,
        expected: String,
        field: String
    ) throws {
        let actual = extensions[key as String] as? String
        guard actual == expected else {
            throw VideoWriterFormatContractV4Error.encodedColorMismatch(
                field: field,
                expected: expected,
                actual: actual
            )
        }
    }
}

private extension PixelStorageV4 {
    init(pixelFormat: OSType) throws {
        self = try PixelLayoutV4(pixelFormat: pixelFormat).storage
    }
}
