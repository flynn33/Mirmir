import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum AVFoundationHDRMetadataAdapterV4 {
    static func probe(
        formatDescription: CMFormatDescription,
        decodedStorage: PixelStorageV4
    ) throws -> HDRFormatMetadataV4? {
        let extensions = (
            CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary?
        ) ?? [:]
        let snapshot = AttachmentSnapshot(
            colorPrimaries: extensions[
                kCMFormatDescriptionExtension_ColorPrimaries as String
            ] as? String,
            transferFunction: extensions[
                kCMFormatDescriptionExtension_TransferFunction as String
            ] as? String,
            yCbCrMatrix: extensions[
                kCMFormatDescriptionExtension_YCbCrMatrix as String
            ] as? String,
            alternativeTransferFunction: extensions[
                kCMFormatDescriptionExtension_AlternativeTransferCharacteristics
                    as String
            ] as? String,
            bitsPerComponent: try integerValue(
                extensions[
                    kCMFormatDescriptionExtension_BitsPerComponent as String
                ],
                key: "bits_per_component"
            ),
            masteringDisplayColorVolume: try dataValue(
                extensions[
                    kCMFormatDescriptionExtension_MasteringDisplayColorVolume
                        as String
                ],
                key: "mastering_display_color_volume"
            ),
            contentLightLevelInfo: try dataValue(
                extensions[
                    kCMFormatDescriptionExtension_ContentLightLevelInfo as String
                ],
                key: "content_light_level_info"
            ),
            ambientViewingEnvironment: try dataValue(
                extensions[
                    kCMFormatDescriptionExtension_AmbientViewingEnvironment
                        as String
                ],
                key: "ambient_viewing_environment"
            )
        )
        return try decode(snapshot, storage: decodedStorage)
    }

    static func probe(
        pixelBuffer: CVPixelBuffer,
        storage: PixelStorageV4,
        fallback: HDRFormatMetadataV4? = nil
    ) throws -> HDRFormatMetadataV4? {
        let layout = PixelLayoutV4(storage: storage)
        try layout.validateStructure(of: pixelBuffer)
        let snapshot = try pixelBufferSnapshot(pixelBuffer)
        if snapshot.isEmpty, let fallback {
            guard fallback.signal.storage == storage else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "fallback HDR storage does not match the decoded buffer"
                )
            }
            return fallback
        }
        let observed = try decode(snapshot, storage: storage)
        if let fallback, let observed, fallback != observed {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "decoded HDR attachments disagree with the format description"
            )
        }
        return observed ?? fallback
    }

    static func migrate(
        _ metadata: HDRFormatMetadataV4,
        to pixelBuffer: CVPixelBuffer
    ) throws {
        let layout = PixelLayoutV4(storage: metadata.signal.storage)
        try layout.validateStructure(of: pixelBuffer)
        let existing = try pixelBufferSnapshot(pixelBuffer)
        let desired = snapshot(for: metadata)
        try rejectContradictions(existing: existing, desired: desired)

        setAttachment(
            kCVImageBufferColorPrimariesKey,
            value: kCVImageBufferColorPrimaries_ITU_R_2020,
            on: pixelBuffer
        )
        setAttachment(
            kCVImageBufferTransferFunctionKey,
            value: cvTransferFunction(metadata.signal.transferFunction),
            on: pixelBuffer
        )
        setAttachment(
            kCVImageBufferYCbCrMatrixKey,
            value: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            on: pixelBuffer
        )
        if let mastering = metadata.staticMetadata.masteringDisplayColorVolume {
            setAttachment(
                kCVImageBufferMasteringDisplayColorVolumeKey,
                value: mastering.payload as CFData,
                on: pixelBuffer
            )
        }
        if let contentLight = metadata.staticMetadata.contentLightLevelInfo {
            setAttachment(
                kCVImageBufferContentLightLevelInfoKey,
                value: contentLight.payload as CFData,
                on: pixelBuffer
            )
        }
        if let ambient = metadata.staticMetadata.ambientViewingEnvironment {
            setAttachment(
                kCVImageBufferAmbientViewingEnvironmentKey,
                value: ambient.payload as CFData,
                on: pixelBuffer
            )
        }
    }

    static func probeDynamicMetadata(
        from sampleBuffer: CMSampleBuffer
    ) throws -> HDRDynamicMetadataV4? {
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount <= 1 else {
            throw HDRMetadataV4Error.unsupportedSampleCount(sampleCount)
        }
        // Image-backed buffers created by Core Media can report zero packet
        // samples even though they represent one decoded video frame. In that
        // representation the per-frame metadata lives on the image buffer.
        if sampleCount == 0,
           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            return try probeDynamicMetadata(from: pixelBuffer)
        }
        guard let dictionary = try sampleAttachmentDictionary(
            sampleBuffer,
            createIfNecessary: false
        ) else {
            return nil
        }
        return try dynamicMetadata(from: dictionary as NSDictionary)
    }

    static func migrate(
        _ metadata: HDRDynamicMetadataV4,
        to sampleBuffer: CMSampleBuffer
    ) throws {
        if CMSampleBufferGetNumSamples(sampleBuffer) == 0,
           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            try migrate(metadata, to: pixelBuffer)
            return
        }
        let existing = try probeDynamicMetadata(from: sampleBuffer)
        if let existing, existing != metadata {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "destination sample carries different dynamic HDR metadata"
            )
        }
        guard existing == nil else { return }
        let dictionary = try sampleAttachmentDictionary(
            sampleBuffer,
            createIfNecessary: true
        )
        guard let dictionary else {
            throw HDRMetadataV4Error.unsupportedSampleCount(
                CMSampleBufferGetNumSamples(sampleBuffer)
            )
        }
        if let hdr10Plus = metadata.hdr10Plus {
            setDictionaryValue(
                hdr10Plus.ituTT35Payload as CFData,
                for: kCMSampleAttachmentKey_HDR10PlusPerFrameData,
                in: dictionary
            )
        }
        if let postDecode = metadata.postDecodeProcessing {
            setDictionaryValue(
                try postDecode.propertyListDictionary(),
                for: kCMSampleAttachmentKey_PostDecodeProcessingMetadata,
                in: dictionary
            )
        }
    }

    static func probeDynamicMetadata(
        from pixelBuffer: CVPixelBuffer
    ) throws -> HDRDynamicMetadataV4? {
        var values: [String: Any] = [:]
        if let hdr10Plus = CVBufferCopyAttachment(
            pixelBuffer,
            kCMSampleAttachmentKey_HDR10PlusPerFrameData,
            nil
        ) {
            values[
                kCMSampleAttachmentKey_HDR10PlusPerFrameData as String
            ] = hdr10Plus
        }
        if let postDecode = CVBufferCopyAttachment(
            pixelBuffer,
            kCMSampleAttachmentKey_PostDecodeProcessingMetadata,
            nil
        ) {
            values[
                kCMSampleAttachmentKey_PostDecodeProcessingMetadata as String
            ] = postDecode
        }
        return try dynamicMetadata(from: values as NSDictionary)
    }

    static func migrate(
        _ metadata: HDRDynamicMetadataV4,
        to pixelBuffer: CVPixelBuffer
    ) throws {
        let existing = try probeDynamicMetadata(from: pixelBuffer)
        if let existing, existing != metadata {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "destination pixel buffer carries different dynamic HDR metadata"
            )
        }
        guard existing == nil else { return }
        if let hdr10Plus = metadata.hdr10Plus {
            setAttachment(
                kCMSampleAttachmentKey_HDR10PlusPerFrameData,
                value: hdr10Plus.ituTT35Payload as CFData,
                on: pixelBuffer
            )
        }
        if let postDecode = metadata.postDecodeProcessing {
            setAttachment(
                kCMSampleAttachmentKey_PostDecodeProcessingMetadata,
                value: try postDecode.propertyListDictionary(),
                on: pixelBuffer
            )
        }
    }

    static func formatDescriptionExtensions(
        for metadata: HDRFormatMetadataV4
    ) -> [CFString: Any] {
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries:
                kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction:
                cmTransferFunction(metadata.signal.transferFunction),
            kCMFormatDescriptionExtension_YCbCrMatrix:
                kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            kCMFormatDescriptionExtension_BitsPerComponent: NSNumber(value: 10)
        ]
        if let mastering = metadata.staticMetadata.masteringDisplayColorVolume {
            extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] =
                mastering.payload as CFData
        }
        if let contentLight = metadata.staticMetadata.contentLightLevelInfo {
            extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] =
                contentLight.payload as CFData
        }
        if let ambient = metadata.staticMetadata.ambientViewingEnvironment {
            extensions[kCMFormatDescriptionExtension_AmbientViewingEnvironment] =
                ambient.payload as CFData
        }
        return extensions
    }

    static func avFoundationColorProperties(
        for signal: HDRSignalV4
    ) -> [String: String] {
        [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: avTransferFunction(
                signal.transferFunction
            ),
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
        ]
    }

    static func videoToolboxCompressionProperties(
        for metadata: HDRFormatMetadataV4,
        dynamicPolicy: HDRDynamicEncodingPolicyV4,
        pixelsWereModified: Bool
    ) throws -> [String: Any] {
        if dynamicPolicy == .preserveSourceWhenPixelsAreUnmodified,
           pixelsWereModified {
            throw HDRMetadataV4Error.dynamicMetadataRequiresRegeneration
        }
        var properties: [String: Any] = [
            kVTCompressionPropertyKey_HDRMetadataInsertionMode as String:
                kVTHDRMetadataInsertionMode_Auto
        ]
        if let mastering = metadata.staticMetadata.masteringDisplayColorVolume {
            properties[
                kVTCompressionPropertyKey_MasteringDisplayColorVolume as String
            ] = mastering.payload
        }
        if let contentLight = metadata.staticMetadata.contentLightLevelInfo {
            properties[
                kVTCompressionPropertyKey_ContentLightLevelInfo as String
            ] = contentLight.payload
        }
        if dynamicPolicy == .preserveSourceWhenPixelsAreUnmodified
            || dynamicPolicy
                == .preserveSourceSceneMetadataAcrossSpatialResampling
            || dynamicPolicy
                == .replicateSourceSceneMetadataAcrossFieldNormalization {
            properties[
                kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String
            ] = true
        }
        return properties
    }

    private struct AttachmentSnapshot {
        let colorPrimaries: String?
        let transferFunction: String?
        let yCbCrMatrix: String?
        let alternativeTransferFunction: String?
        let bitsPerComponent: Int?
        let masteringDisplayColorVolume: Data?
        let contentLightLevelInfo: Data?
        let ambientViewingEnvironment: Data?

        var isEmpty: Bool {
            colorPrimaries == nil
                && transferFunction == nil
                && yCbCrMatrix == nil
                && alternativeTransferFunction == nil
                && bitsPerComponent == nil
                && masteringDisplayColorVolume == nil
                && contentLightLevelInfo == nil
                && ambientViewingEnvironment == nil
        }
    }

    private static func decode(
        _ snapshot: AttachmentSnapshot,
        storage: PixelStorageV4
    ) throws -> HDRFormatMetadataV4? {
        let colorTagCount = [
            snapshot.colorPrimaries,
            snapshot.transferFunction,
            snapshot.yCbCrMatrix
        ].compactMap { $0 }.count
        guard colorTagCount == 0 || colorTagCount == 3 else {
            throw HDRMetadataV4Error.incompleteHDRColorTags
        }

        let transfer: HDRTransferFunctionV4?
        if snapshot.transferFunction
            == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String {
            transfer = .pq
        } else if snapshot.transferFunction
            == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String {
            transfer = .hlg
        } else {
            transfer = nil
        }

        let alternativeDeclaresHDR = isHDRTransferFunction(
            snapshot.alternativeTransferFunction
        )
        if alternativeDeclaresHDR,
           snapshot.alternativeTransferFunction != snapshot.transferFunction {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "alternative HDR transfer function disagrees with the primary tag"
            )
        }

        let hasStaticMetadata = snapshot.masteringDisplayColorVolume != nil
            || snapshot.contentLightLevelInfo != nil
            || snapshot.ambientViewingEnvironment != nil
        guard let transfer else {
            if hasStaticMetadata {
                throw HDRMetadataV4Error.staticMetadataWithoutHDRTransfer
            }
            return nil
        }
        if let bitsPerComponent = snapshot.bitsPerComponent,
           bitsPerComponent != 10 {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "HDR format declares \(bitsPerComponent) bits instead of 10"
            )
        }
        guard snapshot.colorPrimaries
                == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String else {
            throw HDRMetadataV4Error.unsupportedColorTag(
                key: "color_primaries",
                value: snapshot.colorPrimaries
            )
        }
        guard snapshot.yCbCrMatrix
                == kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String else {
            throw HDRMetadataV4Error.unsupportedColorTag(
                key: "ycbcr_matrix",
                value: snapshot.yCbCrMatrix
            )
        }
        if let alternative = snapshot.alternativeTransferFunction,
           alternative != snapshot.transferFunction {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "alternative transfer function disagrees with the HDR transfer"
            )
        }

        return HDRFormatMetadataV4(
            signal: try HDRSignalV4(
                storage: storage,
                transferFunction: transfer
            ),
            staticMetadata: HDRStaticMetadataV4(
                masteringDisplayColorVolume: try snapshot
                    .masteringDisplayColorVolume
                    .map(MasteringDisplayColorVolumeV4.init(payload:)),
                contentLightLevelInfo: try snapshot.contentLightLevelInfo
                    .map(ContentLightLevelInfoV4.init(payload:)),
                ambientViewingEnvironment: try snapshot
                    .ambientViewingEnvironment
                    .map(AmbientViewingEnvironmentV4.init(payload:))
            )
        )
    }

    private static func pixelBufferSnapshot(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> AttachmentSnapshot {
        AttachmentSnapshot(
            colorPrimaries: CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                nil
            ) as? String,
            transferFunction: CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferTransferFunctionKey,
                nil
            ) as? String,
            yCbCrMatrix: CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferYCbCrMatrixKey,
                nil
            ) as? String,
            alternativeTransferFunction: nil,
            bitsPerComponent: nil,
            masteringDisplayColorVolume: try dataValue(
                CVBufferCopyAttachment(
                    pixelBuffer,
                    kCVImageBufferMasteringDisplayColorVolumeKey,
                    nil
                ),
                key: "mastering_display_color_volume"
            ),
            contentLightLevelInfo: try dataValue(
                CVBufferCopyAttachment(
                    pixelBuffer,
                    kCVImageBufferContentLightLevelInfoKey,
                    nil
                ),
                key: "content_light_level_info"
            ),
            ambientViewingEnvironment: try dataValue(
                CVBufferCopyAttachment(
                    pixelBuffer,
                    kCVImageBufferAmbientViewingEnvironmentKey,
                    nil
                ),
                key: "ambient_viewing_environment"
            )
        )
    }

    private static func snapshot(
        for metadata: HDRFormatMetadataV4
    ) -> AttachmentSnapshot {
        AttachmentSnapshot(
            colorPrimaries:
                kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String,
            transferFunction: cmTransferFunction(
                metadata.signal.transferFunction
            ) as String,
            yCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String,
            alternativeTransferFunction: nil,
            bitsPerComponent: 10,
            masteringDisplayColorVolume: metadata.staticMetadata
                .masteringDisplayColorVolume?.payload,
            contentLightLevelInfo: metadata.staticMetadata
                .contentLightLevelInfo?.payload,
            ambientViewingEnvironment: metadata.staticMetadata
                .ambientViewingEnvironment?.payload
        )
    }

    private static func rejectContradictions(
        existing: AttachmentSnapshot,
        desired: AttachmentSnapshot
    ) throws {
        let fields: [(String, AnyHashable?, AnyHashable?)] = [
            ("color_primaries", existing.colorPrimaries, desired.colorPrimaries),
            ("transfer_function", existing.transferFunction, desired.transferFunction),
            ("ycbcr_matrix", existing.yCbCrMatrix, desired.yCbCrMatrix),
            (
                "bits_per_component",
                existing.bitsPerComponent,
                desired.bitsPerComponent
            ),
            (
                "mastering_display_color_volume",
                existing.masteringDisplayColorVolume,
                desired.masteringDisplayColorVolume
            ),
            (
                "content_light_level_info",
                existing.contentLightLevelInfo,
                desired.contentLightLevelInfo
            ),
            (
                "ambient_viewing_environment",
                existing.ambientViewingEnvironment,
                desired.ambientViewingEnvironment
            )
        ]
        for (name, oldValue, newValue) in fields {
            if let oldValue, oldValue != newValue {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "existing \(name) attachment differs from the migration plan"
                )
            }
        }
    }

    private static func dynamicMetadata(
        from dictionary: NSDictionary
    ) throws -> HDRDynamicMetadataV4? {
        let rawHDR10Plus = dictionary[
            kCMSampleAttachmentKey_HDR10PlusPerFrameData as String
        ]
        let rawPostDecode = dictionary[
            kCMSampleAttachmentKey_PostDecodeProcessingMetadata as String
        ]
        let hdr10Plus: HDR10PlusMetadataV4?
        if let rawHDR10Plus {
            guard let payload = rawHDR10Plus as? Data else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "HDR10+ attachment is not CFData"
                )
            }
            hdr10Plus = try HDR10PlusMetadataV4(ituTT35Payload: payload)
        } else {
            hdr10Plus = nil
        }
        let postDecode: PostDecodeProcessingMetadataV4?
        if let rawPostDecode {
            guard rawPostDecode is NSDictionary else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "post-decode HDR attachment is not a dictionary"
                )
            }
            postDecode = try PostDecodeProcessingMetadataV4(
                propertyList: rawPostDecode
            )
        } else {
            postDecode = nil
        }
        let metadata = HDRDynamicMetadataV4(
            hdr10Plus: hdr10Plus,
            postDecodeProcessing: postDecode
        )
        return metadata.isEmpty ? nil : metadata
    }

    private static func dataValue(_ value: Any?, key: String) throws -> Data? {
        guard let value else { return nil }
        guard let data = value as? Data else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "\(key) attachment is not CFData"
            )
        }
        return data
    }

    private static func integerValue(_ value: Any?, key: String) throws -> Int? {
        guard let value else { return nil }
        guard let number = value as? NSNumber else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "\(key) attachment is not CFNumber"
            )
        }
        return number.intValue
    }

    private static func sampleAttachmentDictionary(
        _ sampleBuffer: CMSampleBuffer,
        createIfNecessary: Bool
    ) throws -> CFMutableDictionary? {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: createIfNecessary
        ) else {
            return nil
        }
        let count = CFArrayGetCount(array)
        // Core Media may represent a single image sample with no attachments
        // as an existing, empty attachment array. That is semantically the
        // same as no attachment array when probing; it is not a malformed
        // multi-sample buffer.
        if count == 0, !createIfNecessary {
            return nil
        }
        guard count == 1 else {
            throw HDRMetadataV4Error.unsupportedSampleCount(count)
        }
        return unsafeBitCast(
            CFArrayGetValueAtIndex(array, 0),
            to: CFMutableDictionary.self
        )
    }

    private static func setDictionaryValue(
        _ value: CFTypeRef,
        for key: CFString,
        in dictionary: CFMutableDictionary
    ) {
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(value).toOpaque()
        )
    }

    private static func setAttachment(
        _ key: CFString,
        value: CFTypeRef,
        on pixelBuffer: CVPixelBuffer
    ) {
        CVBufferSetAttachment(
            pixelBuffer,
            key,
            value,
            .shouldPropagate
        )
    }

    private static func cvTransferFunction(
        _ transfer: HDRTransferFunctionV4
    ) -> CFString {
        switch transfer {
        case .pq:
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .hlg:
            kCVImageBufferTransferFunction_ITU_R_2100_HLG
        }
    }

    private static func cmTransferFunction(
        _ transfer: HDRTransferFunctionV4
    ) -> CFString {
        switch transfer {
        case .pq:
            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case .hlg:
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        }
    }

    private static func avTransferFunction(
        _ transfer: HDRTransferFunctionV4
    ) -> String {
        switch transfer {
        case .pq:
            AVVideoTransferFunction_SMPTE_ST_2084_PQ
        case .hlg:
            AVVideoTransferFunction_ITU_R_2100_HLG
        }
    }

    private static func isHDRTransferFunction(_ value: String?) -> Bool {
        value == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
            || value
                == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
    }
}
