import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum AlphaVideoWriterCodecV4: String, CaseIterable, Codable, Hashable,
    Sendable {
    case proRes4444
    case proRes4444XQ
    case hevcWithAlpha

    var avVideoCodecType: AVVideoCodecType {
        switch self {
        case .proRes4444:
            return .proRes4444
        case .proRes4444XQ:
            return .appleProRes4444XQ
        case .hevcWithAlpha:
            return .hevcWithAlpha
        }
    }

    /// `AVVideoCodecType.hevcWithAlpha` is an encoder-selection token. The
    /// resulting backwards-compatible elementary stream is tagged `hvc1`.
    var encodedMediaSubtype: CMVideoCodecType {
        switch self {
        case .proRes4444:
            return kCMVideoCodecType_AppleProRes4444
        case .proRes4444XQ:
            return kCMVideoCodecType_AppleProRes4444XQ
        case .hevcWithAlpha:
            return kCMVideoCodecType_HEVC
        }
    }

    var preservesAlphaBytesExactly: Bool {
        switch self {
        case .proRes4444, .proRes4444XQ:
            return true
        case .hevcWithAlpha:
            return false
        }
    }
}

enum AlphaVideoWriterContractV4Error: Error, Equatable, Sendable {
    case nonPositiveDimensions(width: Int, height: Int)
    case dimensionsExceedEngineLimit(width: Int, height: Int, limit: Int)
    case unsupportedInputLayout(
        codec: AlphaVideoWriterCodecV4,
        layout: Alpha4444PackedLayoutV4
    )
    case writerRejectedOutputSettings(codec: AlphaVideoWriterCodecV4)
    case writerRejectedInput(codec: AlphaVideoWriterCodecV4)
    case inputPixelFormatMismatch(expected: OSType, actual: OSType)
    case inputDimensionMismatch(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case inputAlphaAssociationMissing
    case inputAlphaAssociationMismatch(
        expected: AlphaAssociationV4,
        actual: String
    )
    case encodedMediaTypeMismatch(actual: CMMediaType)
    case encodedCodecMismatch(expected: CMVideoCodecType, actual: CMVideoCodecType)
    case encodedDimensionMismatch(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int32,
        actualHeight: Int32
    )
    case encodedAlphaPresenceMissingOrFalse
    case encodedAlphaAssociationMissing
    case encodedAlphaAssociationMismatch(
        expected: AlphaAssociationV4,
        actual: String
    )
    case encodedProResAlphaDepthMismatch(actual: Int?)
}

struct AlphaVideoWriterEndpointV4 {
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
}

/// Alpha-specific AVFoundation writer/decoder contract.
///
/// The contract deliberately admits only Core Video layouts publicly
/// recommended for each encoder: BGRA for HEVC-alpha and 8-bit ProRes input,
/// or 64-bit big-endian ARGB for high-bit-depth ProRes 4444. It never asks
/// AVFoundation to scale or color-match a high-bit-depth ProRes source.
struct AlphaVideoWriterContractV4: Hashable, Sendable {
    let codec: AlphaVideoWriterCodecV4
    let association: AlphaAssociationV4
    let width: Int
    let height: Int
    let inputLayout: Alpha4444PackedLayoutV4

    init(
        codec: AlphaVideoWriterCodecV4,
        association: AlphaAssociationV4,
        width: Int,
        height: Int,
        inputLayout: Alpha4444PackedLayoutV4
    ) throws {
        guard width > 0, height > 0 else {
            throw AlphaVideoWriterContractV4Error.nonPositiveDimensions(
                width: width,
                height: height
            )
        }
        let limit = SpatialAxisScalePlanV4.maximumSupportedExtent
        guard width <= limit, height <= limit else {
            throw AlphaVideoWriterContractV4Error.dimensionsExceedEngineLimit(
                width: width,
                height: height,
                limit: limit
            )
        }
        let supported: Set<Alpha4444PackedLayoutV4>
        switch codec {
        case .proRes4444, .proRes4444XQ:
            supported = [.bgra8, .argb16BigEndian]
        case .hevcWithAlpha:
            supported = [.bgra8]
        }
        guard supported.contains(inputLayout) else {
            throw AlphaVideoWriterContractV4Error.unsupportedInputLayout(
                codec: codec,
                layout: inputLayout
            )
        }
        self.codec = codec
        self.association = association
        self.width = width
        self.height = height
        self.inputLayout = inputLayout
    }

    var outputSettings: [String: Any] {
        [
            AVVideoCodecKey: codec.avVideoCodecType,
            AVVideoWidthKey: NSNumber(value: width),
            AVVideoHeightKey: NSNumber(value: height),
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
    }

    var sourcePixelBufferAttributes: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: inputLayout.pixelFormat),
            kCVPixelBufferWidthKey as String: NSNumber(value: width),
            kCVPixelBufferHeightKey as String: NSNumber(value: height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
    }

    /// Decode at the encoded raster size. In particular, AVAssetReader does
    /// not support width/height scaling for 64ARGB ProRes output.
    var decoderOutputSettings: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: inputLayout.pixelFormat)
        ]
    }

    var compressionProperties: [String: Any] {
        var properties: [String: Any] = [
            kVTCompressionPropertyKey_AlphaChannelMode as String:
                compressionAlphaMode
        ]
        switch codec {
        case .proRes4444, .proRes4444XQ:
            // This property is supported by ProRes and makes preservation an
            // explicit contract rather than relying on its default value.
            properties[
                kVTCompressionPropertyKey_PreserveAlphaChannel as String
            ] = kCFBooleanTrue
        case .hevcWithAlpha:
            // PreserveAlphaChannel is not supported by every HEVC-alpha
            // encoder. The muxed-alpha codec selector itself is the required
            // preservation contract; quality 1 requests its highest alpha
            // fidelity without falsely promising mathematical losslessness.
            properties[
                kVTCompressionPropertyKey_TargetQualityForAlpha as String
            ] = NSNumber(value: 1.0)
        }
        return properties
    }

    func preflight(writer: AVAssetWriter) throws {
        guard writer.canApply(
            outputSettings: outputSettings,
            forMediaType: .video
        ) else {
            throw AlphaVideoWriterContractV4Error
                .writerRejectedOutputSettings(codec: codec)
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: outputSettings
        )
        guard writer.canAdd(input) else {
            throw AlphaVideoWriterContractV4Error
                .writerRejectedInput(codec: codec)
        }
    }

    func makeEndpoint(writer: AVAssetWriter) throws -> AlphaVideoWriterEndpointV4 {
        guard writer.canApply(
            outputSettings: outputSettings,
            forMediaType: .video
        ) else {
            throw AlphaVideoWriterContractV4Error
                .writerRejectedOutputSettings(codec: codec)
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: outputSettings
        )
        guard writer.canAdd(input) else {
            throw AlphaVideoWriterContractV4Error
                .writerRejectedInput(codec: codec)
        }
        writer.add(input)
        return AlphaVideoWriterEndpointV4(
            input: input,
            adaptor: AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )
        )
    }

    func validateInputPixelBuffer(_ pixelBuffer: CVPixelBuffer) throws {
        let actualFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard actualFormat == inputLayout.pixelFormat else {
            throw AlphaVideoWriterContractV4Error.inputPixelFormatMismatch(
                expected: inputLayout.pixelFormat,
                actual: actualFormat
            )
        }
        let actualWidth = CVPixelBufferGetWidth(pixelBuffer)
        let actualHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard actualWidth == width, actualHeight == height else {
            throw AlphaVideoWriterContractV4Error.inputDimensionMismatch(
                expectedWidth: width,
                expectedHeight: height,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
        guard let actual = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferAlphaChannelModeKey,
            nil
        ) as? String else {
            throw AlphaVideoWriterContractV4Error.inputAlphaAssociationMissing
        }
        let expected = imageBufferAlphaMode as String
        guard actual == expected else {
            throw AlphaVideoWriterContractV4Error
                .inputAlphaAssociationMismatch(
                    expected: association,
                    actual: actual
                )
        }
    }

    func installAssociationAttachment(on pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferAlphaChannelModeKey,
            imageBufferAlphaMode,
            .shouldPropagate
        )
    }

    func validateEncodedFormatDescription(
        _ description: CMFormatDescription
    ) throws {
        let mediaType = CMFormatDescriptionGetMediaType(description)
        guard mediaType == kCMMediaType_Video else {
            throw AlphaVideoWriterContractV4Error
                .encodedMediaTypeMismatch(actual: mediaType)
        }
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        guard subtype == codec.encodedMediaSubtype else {
            throw AlphaVideoWriterContractV4Error.encodedCodecMismatch(
                expected: codec.encodedMediaSubtype,
                actual: subtype
            )
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width == Int32(width),
              dimensions.height == Int32(height) else {
            throw AlphaVideoWriterContractV4Error.encodedDimensionMismatch(
                expectedWidth: width,
                expectedHeight: height,
                actualWidth: dimensions.width,
                actualHeight: dimensions.height
            )
        }

        let extensions = CMFormatDescriptionGetExtensions(description)
            as NSDictionary?
        let containsAlpha = extensions?[
            kCMFormatDescriptionExtension_ContainsAlphaChannel as String
        ]
        guard let alphaNumber = containsAlpha as? NSNumber,
              CFGetTypeID(alphaNumber) == CFBooleanGetTypeID(),
              alphaNumber.boolValue else {
            throw AlphaVideoWriterContractV4Error
                .encodedAlphaPresenceMissingOrFalse
        }
        guard let actualMode = extensions?[
            kCMFormatDescriptionExtension_AlphaChannelMode as String
        ] as? String else {
            throw AlphaVideoWriterContractV4Error
                .encodedAlphaAssociationMissing
        }
        let expectedMode = formatDescriptionAlphaMode as String
        guard actualMode == expectedMode else {
            throw AlphaVideoWriterContractV4Error
                .encodedAlphaAssociationMismatch(
                    expected: association,
                    actual: actualMode
                )
        }

        if codec == .proRes4444 || codec == .proRes4444XQ {
            let depth = (extensions?[
                kCMFormatDescriptionExtension_Depth as String
            ] as? NSNumber)?.intValue
            guard depth == 32 else {
                throw AlphaVideoWriterContractV4Error
                    .encodedProResAlphaDepthMismatch(actual: depth)
            }
        }
    }

    private var compressionAlphaMode: CFString {
        switch association {
        case .straight:
            return kVTAlphaChannelMode_StraightAlpha
        case .premultiplied:
            return kVTAlphaChannelMode_PremultipliedAlpha
        }
    }

    private var imageBufferAlphaMode: CFString {
        switch association {
        case .straight:
            return kCVImageBufferAlphaChannelMode_StraightAlpha
        case .premultiplied:
            return kCVImageBufferAlphaChannelMode_PremultipliedAlpha
        }
    }

    private var formatDescriptionAlphaMode: CFString {
        switch association {
        case .straight:
            return kCMFormatDescriptionAlphaChannelMode_StraightAlpha
        case .premultiplied:
            return kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha
        }
    }
}

enum AVFoundationAlphaVideoWriterV4Error: Error, Equatable, Sendable {
    case exactVerificationRequiresProRes4444(AlphaVideoWriterCodecV4)
    case writerCreationFailed(String)
    case writerStartFailed(String)
    case alreadyTerminal
    case noFramesAppended
    case invalidPresentationTime(frameOrdinal: Int)
    case nonMonotonicPresentationTime(frameOrdinal: Int)
    case writerStoppedAcceptingFrames(String)
    case writerAppendFailed(frameOrdinal: Int, failure: String)
    case writerFinishFailed(String)
    case encodedVideoTrackCountMismatch(Int)
    case encodedVideoTrackOrdinalOutOfRange(requested: Int, count: Int)
    case encodedFormatDescriptionMissing
    case encodedFormatFingerprintMismatch(
        expected: ASHSHA256V4,
        actual: ASHSHA256V4
    )
    case processedSampleHasNoImageBuffer(frameOrdinal: Int)
    case readerRejectedOutput
    case readerStartFailed(String)
    case decodedFrameCountExceeded(expected: Int)
    case decodedFrameCountMismatch(expected: Int, actual: Int)
    case decodedSampleHasNoImageBuffer(frameOrdinal: Int)
    case decodedPresentationTimeMismatch(frameOrdinal: Int)
    case decodedAlphaByteCountMismatch(
        frameOrdinal: Int,
        expected: Int,
        actual: Int
    )
    case decodedAlphaFingerprintMismatch(
        frameOrdinal: Int,
        expected: ASHSHA256V4,
        actual: ASHSHA256V4
    )
    case readerFinishFailed(String)
    case calibrationPixelBufferAllocationFailed(Int32)
}

struct AlphaVideoVerifiedFrameV4: Codable, Equatable, Hashable, Sendable {
    let ordinal: Int
    let presentationTime: ExactRationalV4
    let alphaByteCount: Int
    let sourceAlphaSHA256: ASHSHA256V4
    let decodedAlphaSHA256: ASHSHA256V4
}

struct AlphaVideoWriterVerificationV4: Codable, Equatable, Hashable,
    Sendable {
    static let schemaID = "ash.alpha-video-writer-verification.v4.1"

    let schemaID: String
    let codec: AlphaVideoWriterCodecV4
    let association: AlphaAssociationV4
    let inputLayout: Alpha4444PackedLayoutV4
    let width: Int
    let height: Int
    let encodedFormat: MediaTrackFormatDescriptorV4
    let frames: [AlphaVideoVerifiedFrameV4]

    init(
        contract: AlphaVideoWriterContractV4,
        encodedFormat: MediaTrackFormatDescriptorV4,
        frames: [AlphaVideoVerifiedFrameV4]
    ) {
        self.schemaID = Self.schemaID
        self.codec = contract.codec
        self.association = contract.association
        self.inputLayout = contract.inputLayout
        self.width = contract.width
        self.height = contract.height
        self.encodedFormat = encodedFormat
        self.frames = frames
    }
}

/// Records processed alpha frames at the migration-hook boundary and verifies
/// the completed whole-asset output after AVAssetWriter has closed it. The
/// ledger is bounded to one SHA-256 and timing value per frame; it never keeps
/// full-resolution alpha planes alive across the encode.
actor AVFoundationAlphaVideoOutputVerifierV4 {
    private struct ExpectedFrame: Sendable {
        let presentationTime: CMTime
        let alphaByteCount: Int
        let alphaSHA256: ASHSHA256V4
    }

    private let contract: AlphaVideoWriterContractV4
    private var expectedFrames: [ExpectedFrame] = []
    private var lastPresentationTime: CMTime?
    private var terminalReport: AlphaVideoWriterVerificationV4?
    private var terminal = false

    init(contract: AlphaVideoWriterContractV4) throws {
        guard contract.codec.preservesAlphaBytesExactly else {
            throw AVFoundationAlphaVideoWriterV4Error
                .exactVerificationRequiresProRes4444(contract.codec)
        }
        self.contract = contract
    }

    func record(_ sampleBuffer: CMSampleBuffer) throws {
        let ordinal = expectedFrames.count
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw AVFoundationAlphaVideoWriterV4Error
                .processedSampleHasNoImageBuffer(frameOrdinal: ordinal)
        }
        try record(
            pixelBuffer,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(
                sampleBuffer
            )
        )
    }

    func record(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime
    ) throws {
        guard !terminal, terminalReport == nil else {
            throw AVFoundationAlphaVideoWriterV4Error.alreadyTerminal
        }
        let ordinal = expectedFrames.count
        guard presentationTime.isNumeric,
              presentationTime.epoch == 0,
              presentationTime.timescale > 0,
              CMTimeCompare(presentationTime, .zero) >= 0 else {
            throw AVFoundationAlphaVideoWriterV4Error
                .invalidPresentationTime(frameOrdinal: ordinal)
        }
        if let lastPresentationTime,
           CMTimeCompare(presentationTime, lastPresentationTime) <= 0 {
            throw AVFoundationAlphaVideoWriterV4Error
                .nonMonotonicPresentationTime(frameOrdinal: ordinal)
        }
        try contract.validateInputPixelBuffer(pixelBuffer)
        let alpha = try Alpha4444PixelBufferAccessV4.alphaPlaneBytes(
            pixelBuffer,
            layout: contract.inputLayout
        )
        expectedFrames.append(ExpectedFrame(
            presentationTime: presentationTime,
            alphaByteCount: alpha.count,
            alphaSHA256: ASHSHA256V4(rawData: alpha)
        ))
        lastPresentationTime = presentationTime
    }

    func verify(
        outputURL: URL,
        videoTrackOrdinal: Int = 0
    ) async throws -> AlphaVideoWriterVerificationV4 {
        if let terminalReport { return terminalReport }
        guard !terminal else {
            throw AVFoundationAlphaVideoWriterV4Error.alreadyTerminal
        }
        guard !expectedFrames.isEmpty else {
            throw AVFoundationAlphaVideoWriterV4Error.noFramesAppended
        }
        terminal = true
        let asset = AVURLAsset(
            url: outputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.indices.contains(videoTrackOrdinal) else {
            throw AVFoundationAlphaVideoWriterV4Error
                .encodedVideoTrackOrdinalOutOfRange(
                    requested: videoTrackOrdinal,
                    count: tracks.count
                )
        }
        let track = tracks[videoTrackOrdinal]
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else {
            throw AVFoundationAlphaVideoWriterV4Error
                .encodedFormatDescriptionMissing
        }
        try contract.validateEncodedFormatDescription(description)
        let canonical = try AVFoundationTrackGraphAdapterV4
            .canonicalFormatDescriptor(description)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: contract.decoderOutputSettings
        )
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw AVFoundationAlphaVideoWriterV4Error.readerRejectedOutput
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AVFoundationAlphaVideoWriterV4Error.readerStartFailed(
                Self.stableFailure(reader.error)
            )
        }

        var frames: [AlphaVideoVerifiedFrameV4] = []
        frames.reserveCapacity(expectedFrames.count)
        while let sample = output.copyNextSampleBuffer() {
            let ordinal = frames.count
            guard ordinal < expectedFrames.count else {
                reader.cancelReading()
                throw AVFoundationAlphaVideoWriterV4Error
                    .decodedFrameCountExceeded(expected: expectedFrames.count)
            }
            let expected = expectedFrames[ordinal]
            guard CMTimeCompare(
                CMSampleBufferGetPresentationTimeStamp(sample),
                expected.presentationTime
            ) == 0 else {
                reader.cancelReading()
                throw AVFoundationAlphaVideoWriterV4Error
                    .decodedPresentationTimeMismatch(frameOrdinal: ordinal)
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                reader.cancelReading()
                throw AVFoundationAlphaVideoWriterV4Error
                    .decodedSampleHasNoImageBuffer(frameOrdinal: ordinal)
            }
            try contract.validateInputPixelBuffer(pixelBuffer)
            let decodedAlpha = try Alpha4444PixelBufferAccessV4.alphaPlaneBytes(
                pixelBuffer,
                layout: contract.inputLayout
            )
            guard decodedAlpha.count == expected.alphaByteCount else {
                reader.cancelReading()
                throw AVFoundationAlphaVideoWriterV4Error
                    .decodedAlphaByteCountMismatch(
                        frameOrdinal: ordinal,
                        expected: expected.alphaByteCount,
                        actual: decodedAlpha.count
                    )
            }
            let decodedSHA256 = ASHSHA256V4(rawData: decodedAlpha)
            guard decodedSHA256 == expected.alphaSHA256 else {
                reader.cancelReading()
                throw AVFoundationAlphaVideoWriterV4Error
                    .decodedAlphaFingerprintMismatch(
                        frameOrdinal: ordinal,
                        expected: expected.alphaSHA256,
                        actual: decodedSHA256
                    )
            }
            frames.append(AlphaVideoVerifiedFrameV4(
                ordinal: ordinal,
                presentationTime: try ExactRationalV4(
                    expected.presentationTime.value,
                    Int64(expected.presentationTime.timescale)
                ),
                alphaByteCount: expected.alphaByteCount,
                sourceAlphaSHA256: expected.alphaSHA256,
                decodedAlphaSHA256: decodedSHA256
            ))
        }
        guard frames.count == expectedFrames.count else {
            throw AVFoundationAlphaVideoWriterV4Error
                .decodedFrameCountMismatch(
                    expected: expectedFrames.count,
                    actual: frames.count
                )
        }
        guard reader.status == .completed else {
            throw AVFoundationAlphaVideoWriterV4Error.readerFinishFailed(
                Self.stableFailure(reader.error)
            )
        }
        let report = AlphaVideoWriterVerificationV4(
            contract: contract,
            encodedFormat: canonical,
            frames: frames
        )
        terminalReport = report
        return report
    }

    private nonisolated static func stableFailure(_ error: Error?) -> String {
        guard let error else { return "none" }
        let value = error as NSError
        return "\(value.domain):\(value.code)"
    }
}

/// Exact-alpha AVFoundation writer with a mandatory reopen/decode gate.
///
/// Only ProRes 4444 variants are admitted because VideoToolbox documents their
/// alpha plane as mathematically lossless. Every appended frame records a
/// row-padding-independent alpha fingerprint. `finishAndVerify()` reopens the
/// completed movie, validates its real format description and association,
/// decodes every frame into the original packed layout, and requires the exact
/// alpha byte count and SHA-256 for every presentation timestamp.
actor AVFoundationAlphaVideoWriterV4 {
    private struct ExpectedFrame: Sendable {
        let presentationTime: CMTime
        let alphaByteCount: Int
        let alphaSHA256: ASHSHA256V4
    }

    private let outputURL: URL
    private let contract: AlphaVideoWriterContractV4
    private let writer: AVAssetWriter
    private let endpoint: AlphaVideoWriterEndpointV4
    private var expectedFrames: [ExpectedFrame] = []
    private var lastPresentationTime: CMTime?
    private var terminal = false
    private var verification: AlphaVideoWriterVerificationV4?

    init(
        outputURL: URL,
        contract: AlphaVideoWriterContractV4,
        fileType: AVFileType = .mov
    ) throws {
        guard contract.codec.preservesAlphaBytesExactly else {
            throw AVFoundationAlphaVideoWriterV4Error
                .exactVerificationRequiresProRes4444(contract.codec)
        }
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        } catch {
            throw AVFoundationAlphaVideoWriterV4Error.writerCreationFailed(
                Self.stableFailure(error)
            )
        }
        let endpoint = try contract.makeEndpoint(writer: writer)
        guard writer.startWriting() else {
            throw AVFoundationAlphaVideoWriterV4Error.writerStartFailed(
                Self.stableFailure(writer.error)
            )
        }
        writer.startSession(atSourceTime: .zero)
        self.outputURL = outputURL
        self.contract = contract
        self.writer = writer
        self.endpoint = endpoint
    }

    func append(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime
    ) async throws {
        guard !terminal, verification == nil else {
            throw AVFoundationAlphaVideoWriterV4Error.alreadyTerminal
        }
        let ordinal = expectedFrames.count
        guard presentationTime.isNumeric,
              presentationTime.epoch == 0,
              presentationTime.timescale > 0,
              CMTimeCompare(presentationTime, .zero) >= 0 else {
            throw AVFoundationAlphaVideoWriterV4Error
                .invalidPresentationTime(frameOrdinal: ordinal)
        }
        if let lastPresentationTime,
           CMTimeCompare(presentationTime, lastPresentationTime) <= 0 {
            throw AVFoundationAlphaVideoWriterV4Error
                .nonMonotonicPresentationTime(frameOrdinal: ordinal)
        }
        try contract.validateInputPixelBuffer(pixelBuffer)
        let alpha = try Alpha4444PixelBufferAccessV4.alphaPlaneBytes(
            pixelBuffer,
            layout: contract.inputLayout
        )
        do {
            try await waitUntilReady()
            guard endpoint.adaptor.append(
                pixelBuffer,
                withPresentationTime: presentationTime
            ) else {
                throw AVFoundationAlphaVideoWriterV4Error.writerAppendFailed(
                    frameOrdinal: ordinal,
                    failure: Self.stableFailure(writer.error)
                )
            }
        } catch is CancellationError {
            writer.cancelWriting()
            terminal = true
            throw CancellationError()
        }
        expectedFrames.append(ExpectedFrame(
            presentationTime: presentationTime,
            alphaByteCount: alpha.count,
            alphaSHA256: ASHSHA256V4(rawData: alpha)
        ))
        lastPresentationTime = presentationTime
    }

    func finishAndVerify() async throws -> AlphaVideoWriterVerificationV4 {
        if let verification { return verification }
        guard !terminal else {
            throw AVFoundationAlphaVideoWriterV4Error.alreadyTerminal
        }
        guard !expectedFrames.isEmpty else {
            throw AVFoundationAlphaVideoWriterV4Error.noFramesAppended
        }
        endpoint.input.markAsFinished()
        await finish(writer)
        guard writer.status == .completed else {
            terminal = true
            throw AVFoundationAlphaVideoWriterV4Error.writerFinishFailed(
                Self.stableFailure(writer.error)
            )
        }
        do {
            let report = try await verifyCompletedOutput()
            verification = report
            terminal = true
            return report
        } catch {
            terminal = true
            throw error
        }
    }

    func cancel() {
        guard !terminal, verification == nil else { return }
        writer.cancelWriting()
        terminal = true
    }

    private func waitUntilReady() async throws {
        while !endpoint.input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw AVFoundationAlphaVideoWriterV4Error
                    .writerStoppedAcceptingFrames(
                        Self.stableFailure(writer.error)
                    )
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard writer.status == .writing else {
            throw AVFoundationAlphaVideoWriterV4Error
                .writerStoppedAcceptingFrames(Self.stableFailure(writer.error))
        }
    }

    private func verifyCompletedOutput() async throws
        -> AlphaVideoWriterVerificationV4 {
        let asset = AVURLAsset(
            url: outputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else {
            throw AVFoundationAlphaVideoWriterV4Error
                .encodedVideoTrackCountMismatch(tracks.count)
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else {
            throw AVFoundationAlphaVideoWriterV4Error
                .encodedFormatDescriptionMissing
        }
        try contract.validateEncodedFormatDescription(description)
        let canonical = try AVFoundationTrackGraphAdapterV4
            .canonicalFormatDescriptor(description)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: contract.decoderOutputSettings
        )
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw AVFoundationAlphaVideoWriterV4Error.readerRejectedOutput
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AVFoundationAlphaVideoWriterV4Error.readerStartFailed(
                Self.stableFailure(reader.error)
            )
        }

        var frames: [AlphaVideoVerifiedFrameV4] = []
        frames.reserveCapacity(expectedFrames.count)
        while let sample = output.copyNextSampleBuffer() {
            let ordinal = frames.count
            guard ordinal < expectedFrames.count else {
                reader.cancelReading()
                throw AVFoundationAlphaVideoWriterV4Error
                    .decodedFrameCountExceeded(expected: expectedFrames.count)
            }
            let expected = expectedFrames[ordinal]
            guard CMTimeCompare(
                CMSampleBufferGetPresentationTimeStamp(sample),
                expected.presentationTime
            ) == 0 else {
                reader.cancelReading()
                throw AVFoundationAlphaVideoWriterV4Error
                    .decodedPresentationTimeMismatch(frameOrdinal: ordinal)
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                reader.cancelReading()
                throw AVFoundationAlphaVideoWriterV4Error
                    .decodedSampleHasNoImageBuffer(frameOrdinal: ordinal)
            }
            try contract.validateInputPixelBuffer(pixelBuffer)
            let decodedAlpha = try Alpha4444PixelBufferAccessV4.alphaPlaneBytes(
                pixelBuffer,
                layout: contract.inputLayout
            )
            guard decodedAlpha.count == expected.alphaByteCount else {
                reader.cancelReading()
                throw AVFoundationAlphaVideoWriterV4Error
                    .decodedAlphaByteCountMismatch(
                        frameOrdinal: ordinal,
                        expected: expected.alphaByteCount,
                        actual: decodedAlpha.count
                    )
            }
            let decodedSHA256 = ASHSHA256V4(rawData: decodedAlpha)
            guard decodedSHA256 == expected.alphaSHA256 else {
                reader.cancelReading()
                throw AVFoundationAlphaVideoWriterV4Error
                    .decodedAlphaFingerprintMismatch(
                        frameOrdinal: ordinal,
                        expected: expected.alphaSHA256,
                        actual: decodedSHA256
                    )
            }
            frames.append(AlphaVideoVerifiedFrameV4(
                ordinal: ordinal,
                presentationTime: try ExactRationalV4(
                    expected.presentationTime.value,
                    Int64(expected.presentationTime.timescale)
                ),
                alphaByteCount: expected.alphaByteCount,
                sourceAlphaSHA256: expected.alphaSHA256,
                decodedAlphaSHA256: decodedSHA256
            ))
        }
        guard frames.count == expectedFrames.count else {
            throw AVFoundationAlphaVideoWriterV4Error
                .decodedFrameCountMismatch(
                    expected: expectedFrames.count,
                    actual: frames.count
                )
        }
        guard reader.status == .completed else {
            throw AVFoundationAlphaVideoWriterV4Error.readerFinishFailed(
                Self.stableFailure(reader.error)
            )
        }
        return AlphaVideoWriterVerificationV4(
            contract: contract,
            encodedFormat: canonical,
            frames: frames
        )
    }

    private func finish(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
    }

    private nonisolated static func stableFailure(_ error: Error?) -> String {
        guard let error else { return "none" }
        let value = error as NSError
        return "\(value.domain):\(value.code)"
    }
}

/// Produces and caches the encoder's real alpha-bearing format descriptor.
/// The generated signal includes fully transparent, fully opaque, and partial
/// alpha values and passes through the same mandatory exact-alpha writer gate
/// used by production output.
actor AVFoundationAlphaVideoFormatCalibratorV4 {
    private var cache: [
        AlphaVideoWriterContractV4: AlphaVideoWriterVerificationV4
    ] = [:]

    func calibration(
        for contract: AlphaVideoWriterContractV4
    ) async throws -> AlphaVideoWriterVerificationV4 {
        if let cached = cache[contract] { return cached }
        let result = try await calibrate(contract)
        cache[contract] = result
        return result
    }

    func formatDescriptor(
        for contract: AlphaVideoWriterContractV4
    ) async throws -> MediaTrackFormatDescriptorV4 {
        try await calibration(for: contract).encodedFormat
    }

    private func calibrate(
        _ contract: AlphaVideoWriterContractV4
    ) async throws -> AlphaVideoWriterVerificationV4 {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-v4-alpha-format-calibration-\(UUID().uuidString)"
            )
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let pixelBuffer = try makePixelBuffer(contract: contract)
        contract.installAssociationAttachment(on: pixelBuffer)
        try Alpha4444PixelBufferAccessV4.write(
            try calibrationSamples(contract: contract),
            to: pixelBuffer,
            layout: contract.inputLayout
        )
        let writer = try AVFoundationAlphaVideoWriterV4(
            outputURL: url,
            contract: contract
        )
        try await writer.append(pixelBuffer, presentationTime: .zero)
        return try await writer.finishAndVerify()
    }

    private func makePixelBuffer(
        contract: AlphaVideoWriterContractV4
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            contract.width,
            contract.height,
            contract.inputLayout.pixelFormat,
            contract.sourcePixelBufferAttributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw AVFoundationAlphaVideoWriterV4Error
                .calibrationPixelBufferAllocationFailed(status)
        }
        return pixelBuffer
    }

    private func calibrationSamples(
        contract: AlphaVideoWriterContractV4
    ) throws -> [AlphaSampleV4] {
        let maximum = contract.inputLayout.signalBitDepth == 8
            ? UInt16(UInt8.max)
            : UInt16.max
        let modulus = UInt64(maximum) + 1
        var straight: [AlphaSampleV4] = []
        straight.reserveCapacity(contract.width * contract.height)
        for y in 0..<contract.height {
            for x in 0..<contract.width {
                let alpha: UInt16
                if x == 0 || y == 0 {
                    alpha = 0
                } else if x == contract.width - 1
                            || y == contract.height - 1 {
                    alpha = maximum
                } else {
                    alpha = UInt16(
                        (UInt64(x) * 7_001 + UInt64(y) * 11_003) % modulus
                    )
                }
                straight.append(AlphaSampleV4(
                    red: UInt16(
                        (UInt64(x) * 8_111 + UInt64(y) * 5_009 + 1)
                            % modulus
                    ),
                    green: UInt16(
                        (UInt64(x) * 4_003 + UInt64(y) * 9_007 + 3)
                            % modulus
                    ),
                    blue: UInt16(
                        (UInt64(x) * 6_013 + UInt64(y) * 2_009 + 5)
                            % modulus
                    ),
                    alpha: alpha
                ))
            }
        }
        guard contract.association == .premultiplied else { return straight }
        let plan = try AlphaProcessingPlanV4(
            sourceAssociation: .straight,
            destinationAssociation: .premultiplied,
            zeroAlphaPolicy: .clearColor,
            colorDomain: .fullRangeRGB,
            signalBitDepth: contract.inputLayout.signalBitDepth
        )
        return try straight.map { try AlphaProcessingV4.process($0, using: plan) }
    }
}

/// Fully prepared alpha-track delivery facts. The encoder calibration is the
/// real ProRes sample description used by the immutable track graph plan, and
/// the hook retains the prepared deterministic backend through its processor.
struct PreparedAlphaVideoDeliveryV4: Sendable {
    let backend: PreparedAlpha4444UpscalerV4
    let writerContract: AlphaVideoWriterContractV4
    let encoderCalibration: AlphaVideoWriterVerificationV4
    let outputVerifier: AVFoundationAlphaVideoOutputVerifierV4

    var encodedFormatDescriptor: MediaTrackFormatDescriptorV4 {
        encoderCalibration.encodedFormat
    }

    func makeProcessingHook(
        trackID: MediaTrackStableIDV4,
        nominalSourceFrameDuration: ExactRationalV4,
        outputPreferredTransform: CGAffineTransform? = nil,
        outputNaturalSize: CGSize? = nil
    ) throws -> AVFoundationVideoTrackProcessingHookV4 {
        let base = try PreparedFrameUpscalerTrackHookV4.make(
            trackID: trackID,
            preparedBackend: backend,
            writerOutputSettings: writerContract.outputSettings,
            declaredOutputFormats: [encodedFormatDescriptor],
            nominalSourceFrameDuration: nominalSourceFrameDuration,
            outputPreferredTransform: outputPreferredTransform,
            outputNaturalSize: outputNaturalSize
        )
        let verifier = outputVerifier
        return AVFoundationVideoTrackProcessingHookV4(
            trackID: base.trackID,
            readerOutputSettings: base.readerOutputSettings,
            writerOutputSettings: base.writerOutputSettings,
            declaredOutputFormats: base.declaredOutputFormats,
            outputPreferredTransform: base.outputPreferredTransform,
            outputNaturalSize: base.outputNaturalSize,
            outputTimingContract: base.outputTimingContract,
            processTemporal: { input in
                let outputs = try await base.processTemporal(input)
                for output in outputs {
                    try await verifier.record(output.sampleBuffer)
                }
                return outputs
            },
            finish: {
                try await base.finish()
            }
        )
    }

    func makeVerifiedStandaloneWriter(
        outputURL: URL
    ) throws -> AVFoundationAlphaVideoWriterV4 {
        try AVFoundationAlphaVideoWriterV4(
            outputURL: outputURL,
            contract: writerContract
        )
    }

    func verifyMigratedOutput(
        at outputURL: URL,
        videoTrackOrdinal: Int = 0
    ) async throws -> AlphaVideoWriterVerificationV4 {
        let report = try await outputVerifier.verify(
            outputURL: outputURL,
            videoTrackOrdinal: videoTrackOrdinal
        )
        guard report.encodedFormat == encodedFormatDescriptor else {
            throw AVFoundationAlphaVideoWriterV4Error
                .encodedFormatFingerprintMismatch(
                    expected: encodedFormatDescriptor.canonicalFingerprint,
                    actual: report.encodedFormat.canonicalFingerprint
                )
        }
        return report
    }
}

/// One-call preparation surface for the whole-asset planner's alpha branch.
/// No source frame is decoded until the exact-alpha encoder has successfully
/// encoded, reopened, and decoded its transparent calibration fixture.
actor DeterministicAlphaVideoDeliveryPlannerV4 {
    private let calibrator: AVFoundationAlphaVideoFormatCalibratorV4

    init(
        calibrator: AVFoundationAlphaVideoFormatCalibratorV4 = .init()
    ) {
        self.calibrator = calibrator
    }

    func prepare(
        scalePlan: Alpha4444ScalePlanV4,
        executionBackend: Alpha4444ExecutionBackendV4,
        codec: AlphaVideoWriterCodecV4 = .proRes4444
    ) async throws -> PreparedAlphaVideoDeliveryV4 {
        let writerContract = try AlphaVideoWriterContractV4(
            codec: codec,
            association: scalePlan.destinationAssociation,
            width: scalePlan.targetWidth,
            height: scalePlan.targetHeight,
            inputLayout: scalePlan.layout
        )
        let calibration = try await calibrator.calibration(
            for: writerContract
        )
        let backend = try PreparedAlpha4444UpscalerV4(
            backend: executionBackend,
            plan: scalePlan
        )
        let outputVerifier = try AVFoundationAlphaVideoOutputVerifierV4(
            contract: writerContract
        )
        return PreparedAlphaVideoDeliveryV4(
            backend: backend,
            writerContract: writerContract,
            encoderCalibration: calibration,
            outputVerifier: outputVerifier
        )
    }
}
