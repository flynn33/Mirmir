import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum AVFoundationHDRMetadataAdapterV4 {
    static let compressedParserID =
        "ash.hevc-hdr10plus-length-prefixed-parser.v4.1"
    static let compressedRewriterID =
        "ash.hevc-hdr10plus-prefix-sei-rewriter.v4.1"

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
        let attachmentMetadata: HDRDynamicMetadataV4?
        if let dictionary = try sampleAttachmentDictionary(
            sampleBuffer,
            createIfNecessary: false
        ) {
            attachmentMetadata = try dynamicMetadata(
                from: dictionary as NSDictionary
            )
        } else {
            attachmentMetadata = nil
        }
        let compressedHDR10Plus = try compressedHDR10PlusMetadata(
            from: sampleBuffer
        )
        let imageMetadata: HDRDynamicMetadataV4?
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            imageMetadata = try probeDynamicMetadata(from: imageBuffer)
        } else {
            imageMetadata = nil
        }

        func reconcile<Component: Equatable>(
            _ sample: Component?,
            _ image: Component?,
            label: String
        ) throws -> Component? {
            if let sample, let image, sample != image {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "sample and image-buffer \(label) metadata differ"
                )
            }
            return sample ?? image
        }
        let sampleHDR10Plus = try reconcile(
            attachmentMetadata?.hdr10Plus,
            compressedHDR10Plus,
            label: "sample attachment and compressed HDR10+"
        )
        let merged = HDRDynamicMetadataV4(
            hdr10Plus: try reconcile(
                sampleHDR10Plus,
                imageMetadata?.hdr10Plus,
                label: "HDR10+"
            ),
            postDecodeProcessing: try reconcile(
                attachmentMetadata?.postDecodeProcessing,
                imageMetadata?.postDecodeProcessing,
                label: "post-decode"
            )
        )
        return merged.isEmpty ? nil : merged
    }

    /// Parses the length-prefixed HEVC access unit independently of Core
    /// Media's optional HDR10+ attachment materialization. A valid access unit
    /// may carry at most one HDR10+ registered-user-data SEI message.
    static func probeHDR10PlusMetadata(
        inLengthPrefixedHEVCSample sample: Data,
        nalUnitHeaderLength: Int
    ) throws -> HDR10PlusMetadataV4? {
        guard (1...4).contains(nalUnitHeaderLength), !sample.isEmpty else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "compressed HEVC sample layout is invalid"
            )
        }
        var payloads: [HDR10PlusMetadataV4] = []
        var offset = 0
        var sawVCL = false
        while offset < sample.count {
            guard offset + nalUnitHeaderLength <= sample.count else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "compressed HEVC NAL length prefix is truncated"
                )
            }
            var nalLength = 0
            for byte in sample[offset..<(offset + nalUnitHeaderLength)] {
                let (shifted, shiftOverflow) = nalLength
                    .multipliedReportingOverflow(by: 256)
                let (expanded, addOverflow) = shifted
                    .addingReportingOverflow(Int(byte))
                guard !shiftOverflow, !addOverflow else {
                    throw HDRMetadataV4Error.contradictoryMetadata(
                        "compressed HEVC NAL length overflows"
                    )
                }
                nalLength = expanded
            }
            let nalOffset = offset + nalUnitHeaderLength
            let (nalEnd, endOverflow) = nalOffset
                .addingReportingOverflow(nalLength)
            guard !endOverflow, nalLength >= 2, nalEnd <= sample.count else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "compressed HEVC NAL payload is truncated"
                )
            }
            let nal = sample[nalOffset..<nalEnd]
            let first = nal[nal.startIndex]
            let second = nal[nal.index(after: nal.startIndex)]
            guard first & 0x80 == 0, second & 0x07 != 0 else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "compressed HEVC NAL header is invalid"
                )
            }
            let nalType = (first >> 1) & 0x3F
            if nalType <= 31 {
                sawVCL = true
            } else if nalType == 39 || nalType == 40 {
                let escapedRBSP = Data(nal.dropFirst(2))
                let rbsp = try removeHEVCEmulationPrevention(escapedRBSP)
                payloads.append(contentsOf: try hdr10PlusPayloads(in: rbsp))
            }
            offset = nalEnd
        }
        guard offset == sample.count, sawVCL else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "compressed HEVC sample has no complete VCL NAL"
            )
        }
        guard payloads.count <= 1 else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "compressed HEVC sample carries multiple HDR10+ payloads"
            )
        }
        return payloads.first
    }

    static func insertingHDR10PlusMetadata(
        _ metadata: HDR10PlusMetadataV4,
        into sampleBuffer: CMSampleBuffer
    ) throws -> (sampleBuffer: CMSampleBuffer, rewritten: Bool) {
        if let existing = try compressedHDR10PlusMetadata(from: sampleBuffer) {
            guard existing == metadata else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "encoded and expected HDR10+ metadata differ"
                )
            }
            return (sampleBuffer, false)
        }
        let layout = try compressedHEVCSampleLayout(sampleBuffer)
        let insertionOffset = try hevcPrefixSEIInsertionOffset(
            in: layout.bytes,
            nalUnitHeaderLength: layout.nalUnitHeaderLength
        )
        let nal = makeHDR10PlusPrefixSEINAL(metadata.ituTT35Payload)
        guard nal.count < (1 << (layout.nalUnitHeaderLength * 8))
                || layout.nalUnitHeaderLength == 4 else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "HDR10+ prefix SEI exceeds the HEVC NAL length domain"
            )
        }
        var lengthPrefix = Data(
            repeating: 0,
            count: layout.nalUnitHeaderLength
        )
        var length = nal.count
        for index in lengthPrefix.indices.reversed() {
            lengthPrefix[index] = UInt8(length & 0xFF)
            length >>= 8
        }
        guard length == 0 else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "HDR10+ prefix SEI length cannot be represented"
            )
        }
        var rewritten = Data()
        rewritten.reserveCapacity(
            layout.bytes.count + lengthPrefix.count + nal.count
        )
        rewritten.append(layout.bytes.prefix(insertionOffset))
        rewritten.append(lengthPrefix)
        rewritten.append(nal)
        rewritten.append(layout.bytes.suffix(
            from: insertionOffset
        ))
        return (
            try makeCompressedSample(
                from: sampleBuffer,
                format: layout.format,
                bytes: rewritten
            ),
            true
        )
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
                kVTHDRMetadataInsertionMode_None
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

    /// VideoToolbox on macOS 15.4 can omit the requested ambient environment
    /// or manufacture an HLG default. Encoder insertion is disabled below;
    /// restore the declared value in the compressed format, without changing
    /// any coded picture, other SEI message, or unrelated format extension.
    static func correctingEncodedAmbientEnvironment(
        in format: CMFormatDescription,
        expected: HDRFormatMetadataV4
    ) throws -> CMFormatDescription? {
        guard CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video,
              CMFormatDescriptionGetMediaSubType(format)
                == kCMVideoCodecType_HEVC,
              let observed = try probe(
                formatDescription: format,
                decodedStorage: expected.signal.storage
              ),
              observed.signal == expected.signal,
              observed.staticMetadata.masteringDisplayColorVolume
                == expected.staticMetadata.masteringDisplayColorVolume,
              observed.staticMetadata.contentLightLevelInfo
                == expected.staticMetadata.contentLightLevelInfo,
              let sourceExtensions = CMFormatDescriptionGetExtensions(format),
              let atoms = (sourceExtensions as NSDictionary)[
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
              ] as? NSDictionary,
              let configuration = atoms["hvcC"] as? Data else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "encoded HDR contract differs outside the ambient environment"
            )
        }
        let ambient = expected.staticMetadata.ambientViewingEnvironment?.payload
        let correctedConfiguration = try correctingAmbientConfiguration(
            configuration, ambient: ambient
        )
        guard correctedConfiguration != configuration
                || observed.staticMetadata.ambientViewingEnvironment
                    != expected.staticMetadata.ambientViewingEnvironment else {
            return nil
        }
        let extensions = (sourceExtensions as NSDictionary).mutableCopy()
            as! NSMutableDictionary
        let correctedAtoms = atoms.mutableCopy() as! NSMutableDictionary
        correctedAtoms["hvcC"] = correctedConfiguration
        correctedAtoms.removeObject(forKey: "amve")
        extensions[
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ] = correctedAtoms
        extensions.removeObject(
            forKey: kCMFormatDescriptionExtension_VerbatimSampleDescription
        )
        extensions.removeObject(
            forKey: kCMFormatDescriptionExtension_VerbatimISOSampleEntry
        )
        if let ambient {
            extensions[kCMFormatDescriptionExtension_AmbientViewingEnvironment]
                = ambient
        } else {
            extensions.removeObject(
                forKey: kCMFormatDescriptionExtension_AmbientViewingEnvironment
            )
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        var corrected: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: dimensions.width,
            height: dimensions.height,
            extensions: extensions,
            formatDescriptionOut: &corrected
        )
        guard status == noErr, let corrected else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "ambient format creation failed with status \(status)"
            )
        }
        return corrected
    }

    /// Operates only on a caller-owned encoded temporary output. The caller's
    /// existing atomic publication and semantic verification remain mandatory.
    /// AVMutableMovie replaces the selected format descriptions in its header;
    /// it retains every track's existing media table and encoded payload.
    @discardableResult
    static func finalizeEncodedHDRMetadata(
        at url: URL,
        fileType: AVFileType = .mov,
        expectedByTrackOrdinal: [Int: HDRFormatMetadataV4],
        cancellation: () throws -> Void = {}
    ) async throws -> Bool {
        guard !expectedByTrackOrdinal.isEmpty else { return false }
        try cancellation()
        let movie = AVMutableMovie(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await movie.load(.tracks)
        var changes: [
            (AVMutableMovieTrack, CMFormatDescription, CMFormatDescription)
        ] = []
        for ordinal in expectedByTrackOrdinal.keys.sorted() {
            try cancellation()
            guard tracks.indices.contains(ordinal),
                  tracks[ordinal].mediaType == .video,
                  let expected = expectedByTrackOrdinal[ordinal] else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "encoded HDR track ordinal is invalid"
                )
            }
            let track = tracks[ordinal]
            let formats = try await track.load(.formatDescriptions)
            guard !formats.isEmpty else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "encoded HDR track has no format descriptions"
                )
            }
            for format in formats {
                if let corrected = try correctingEncodedAmbientEnvironment(
                    in: format, expected: expected
                ) {
                    changes.append((track, format, corrected))
                }
            }
            // A header correction cannot hide a contradictory in-band SEI.
            // None-mode encoders emit no ambient SEI on the qualified systems.
            let reader = try AVAssetReader(asset: movie)
            let output = AVAssetReaderTrackOutput(
                track: track, outputSettings: nil
            )
            reader.timeRange = try await track.load(.timeRange)
            guard reader.canAdd(output) else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "encoded HDR ambient reader rejected its track"
                )
            }
            reader.add(output)
            guard reader.startReading() else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "encoded HDR ambient reader did not start"
                )
            }
            defer {
                if reader.status == .reading { reader.cancelReading() }
            }
            while let sample = output.copyNextSampleBuffer() {
                try cancellation()
                if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                let layout = try compressedHEVCSampleLayout(sample)
                for nal in try lengthPrefixedHEVCNALUnits(
                    layout.bytes, width: layout.nalUnitHeaderLength
                ) {
                    let type = (nal[0] >> 1) & 0x3F
                    guard type == 39 || type == 40 else { continue }
                    let messages = try hevcSEIMessages(
                        in: removeHEVCEmulationPrevention(Data(nal.dropFirst(2)))
                    )
                    for message in messages where message.type == 148 {
                        guard message.payload == expected.staticMetadata
                            .ambientViewingEnvironment?.payload else {
                            throw HDRMetadataV4Error.contradictoryMetadata(
                                "encoded sample carries a different ambient environment"
                            )
                        }
                    }
                }
            }
            guard reader.status == .completed else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "encoded HDR ambient reader did not complete"
                )
            }
        }
        guard !changes.isEmpty else { return false }
        try cancellation()
        for (track, original, corrected) in changes {
            track.replaceFormatDescription(original, with: corrected)
        }
        try movie.writeHeader(
            to: url, fileType: fileType,
            options: .addMovieHeaderToDestination
        )
        try cancellation()
        return true
    }

    private struct HEVCConfigurationArray {
        let header: UInt8
        var nals: [Data]
    }

    private static func correctingAmbientConfiguration(
        _ configuration: Data, ambient: Data?
    ) throws -> Data {
        guard configuration.count >= 23, configuration[0] == 1 else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "ambient correction requires a complete hvcC configuration"
            )
        }
        var offset = 23
        func readUInt16() throws -> Int {
            guard offset <= configuration.count - 2 else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "hvcC length is truncated"
                )
            }
            let value = Int(configuration[offset]) << 8
                | Int(configuration[offset + 1])
            offset += 2
            return value
        }
        var arrays: [HEVCConfigurationArray] = []
        var observedAmbient: [Data] = []
        for _ in 0..<Int(configuration[22]) {
            guard offset < configuration.count else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "hvcC array is truncated"
                )
            }
            let header = configuration[offset]
            offset += 1
            let count = try readUInt16()
            var nals: [Data] = []
            for _ in 0..<count {
                let length = try readUInt16()
                guard length >= 2, length <= configuration.count - offset else {
                    throw HDRMetadataV4Error.contradictoryMetadata(
                        "hvcC NAL is truncated"
                    )
                }
                let nal = Data(configuration[offset..<(offset + length)])
                offset += length
                guard nal[0] & 0x80 == 0, nal[1] & 0x07 != 0,
                      (nal[0] >> 1) & 0x3F == header & 0x3F else {
                    throw HDRMetadataV4Error.contradictoryMetadata(
                        "hvcC NAL header differs from its array"
                    )
                }
                if header & 0x3F == 39 || header & 0x3F == 40 {
                    let messages = try hevcSEIMessages(
                        in: removeHEVCEmulationPrevention(Data(nal.dropFirst(2)))
                    )
                    let ambientMessages = messages.filter { $0.type == 148 }
                    for message in ambientMessages {
                        _ = try AmbientViewingEnvironmentV4(
                            payload: message.payload
                        )
                        observedAmbient.append(message.payload)
                    }
                    if ambientMessages.isEmpty {
                        nals.append(nal)
                    } else {
                        let retained = messages.filter { $0.type != 148 }
                        if !retained.isEmpty {
                            nals.append(makeHEVCSEINAL(
                                retained, header: Data(nal.prefix(2))
                            ))
                        }
                    }
                } else {
                    nals.append(nal)
                }
            }
            if !nals.isEmpty {
                arrays.append(HEVCConfigurationArray(header: header, nals: nals))
            }
        }
        guard offset == configuration.count else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "hvcC configuration has trailing data"
            )
        }
        if observedAmbient == ambient.map({ [$0] }) ?? [] {
            return configuration
        }
        if let ambient {
            let nal = makeHEVCSEINAL(
                [HEVCSEIMessage(type: 148, payload: ambient)],
                header: Data([0x4E, 0x01])
            )
            if let prefix = arrays.firstIndex(where: { $0.header & 0x3F == 39 }) {
                arrays[prefix].nals.append(nal)
            } else {
                arrays.append(HEVCConfigurationArray(header: 0xA7, nals: [nal]))
            }
        }
        guard arrays.count <= 255 else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "ambient hvcC array count overflows"
            )
        }
        var result = Data(configuration.prefix(22))
        result.append(UInt8(arrays.count))
        func appendUInt16(_ value: Int) throws {
            guard (0...65535).contains(value) else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "ambient hvcC NAL size overflows"
                )
            }
            result.append(UInt8(value >> 8))
            result.append(UInt8(value & 0xFF))
        }
        for array in arrays {
            result.append(array.header)
            try appendUInt16(array.nals.count)
            for nal in array.nals {
                try appendUInt16(nal.count)
                result.append(nal)
            }
        }
        return result
    }

    private static func lengthPrefixedHEVCNALUnits(
        _ bytes: Data, width: Int
    ) throws -> [Data] {
        guard (1...4).contains(width) else {
            throw HDRMetadataV4Error.contradictoryMetadata("invalid HEVC NAL width")
        }
        var offset = 0
        var result: [Data] = []
        while offset < bytes.count {
            guard width <= bytes.count - offset else {
                throw HDRMetadataV4Error.contradictoryMetadata("truncated HEVC NAL prefix")
            }
            var size = 0
            for byte in bytes[offset..<(offset + width)] {
                size = size * 256 + Int(byte)
            }
            offset += width
            guard size >= 2, size <= bytes.count - offset else {
                throw HDRMetadataV4Error.contradictoryMetadata("truncated HEVC NAL")
            }
            let nal = Data(bytes[offset..<(offset + size)])
            guard nal[0] & 0x80 == 0, nal[1] & 0x07 != 0 else {
                throw HDRMetadataV4Error.contradictoryMetadata("invalid HEVC NAL header")
            }
            result.append(nal)
            offset += size
        }
        return result
    }

    private static func makeHEVCSEINAL(
        _ messages: [HEVCSEIMessage], header: Data
    ) -> Data {
        var rbsp = Data()
        func appendExtended(_ value: Int) {
            var remaining = value
            while remaining >= 255 {
                rbsp.append(255)
                remaining -= 255
            }
            rbsp.append(UInt8(remaining))
        }
        for message in messages {
            appendExtended(message.type)
            appendExtended(message.payload.count)
            rbsp.append(message.payload)
        }
        rbsp.append(0x80)
        var result = header
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 3 {
                result.append(3)
                zeros = 0
            }
            result.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return result
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

    static func compressedHDR10PlusMetadata(
        from sampleBuffer: CMSampleBuffer
    ) throws -> HDR10PlusMetadataV4? {
        guard CMSampleBufferGetNumSamples(sampleBuffer) == 1,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaSubType(format)
                == kCMVideoCodecType_HEVC else {
            return nil
        }
        let layout = try compressedHEVCSampleLayout(sampleBuffer)
        return try probeHDR10PlusMetadata(
            inLengthPrefixedHEVCSample: layout.bytes,
            nalUnitHeaderLength: layout.nalUnitHeaderLength
        )
    }

    private struct CompressedHEVCSampleLayout {
        let format: CMFormatDescription
        let bytes: Data
        let nalUnitHeaderLength: Int
    }

    private static func compressedHEVCSampleLayout(
        _ sampleBuffer: CMSampleBuffer
    ) throws -> CompressedHEVCSampleLayout {
        guard CMSampleBufferGetNumSamples(sampleBuffer) == 1,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaSubType(format)
                == kCMVideoCodecType_HEVC,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "dynamic HDR rewrite requires one compressed HEVC sample"
            )
        }
        var parameterSetPointer: UnsafePointer<UInt8>?
        var parameterSetSize = 0
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        let formatStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: &parameterSetPointer,
            parameterSetSizeOut: &parameterSetSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard formatStatus == noErr,
              parameterSetPointer != nil,
              parameterSetSize > 0,
              parameterSetCount >= 3,
              (1...4).contains(Int(nalUnitHeaderLength)) else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "compressed HEVC format description is incomplete"
            )
        }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        guard byteCount > 0 else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "compressed HEVC sample is empty"
            )
        }
        var bytes = Data(count: byteCount)
        let copyStatus = bytes.withUnsafeMutableBytes { destination in
            guard let baseAddress = destination.baseAddress else {
                return kCMBlockBufferBadLengthParameterErr
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: baseAddress
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "compressed HEVC block-buffer copy failed with status "
                    + "\(copyStatus)"
            )
        }
        return CompressedHEVCSampleLayout(
            format: format,
            bytes: bytes,
            nalUnitHeaderLength: Int(nalUnitHeaderLength)
        )
    }

    private static func hevcPrefixSEIInsertionOffset(
        in sample: Data,
        nalUnitHeaderLength: Int
    ) throws -> Int {
        var offset = 0
        while offset < sample.count {
            guard offset + nalUnitHeaderLength <= sample.count else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "compressed HEVC NAL length prefix is truncated"
                )
            }
            var nalLength = 0
            for byte in sample[offset..<(offset + nalUnitHeaderLength)] {
                nalLength = (nalLength << 8) | Int(byte)
            }
            let nalOffset = offset + nalUnitHeaderLength
            let (nalEnd, overflow) = nalOffset
                .addingReportingOverflow(nalLength)
            guard !overflow, nalLength >= 2, nalEnd <= sample.count else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "compressed HEVC NAL payload is truncated"
                )
            }
            let nalType = (sample[nalOffset] >> 1) & 0x3F
            if nalType <= 31 { return offset }
            offset = nalEnd
        }
        throw HDRMetadataV4Error.contradictoryMetadata(
            "compressed HEVC sample has no complete VCL NAL"
        )
    }

    private static func makeHDR10PlusPrefixSEINAL(_ payload: Data) -> Data {
        var rbsp = Data()
        rbsp.append(0x04)
        var remaining = payload.count
        while remaining >= 0xFF {
            rbsp.append(0xFF)
            remaining -= 0xFF
        }
        rbsp.append(UInt8(remaining))
        rbsp.append(payload)
        rbsp.append(0x80)

        var escaped = Data()
        escaped.reserveCapacity(rbsp.count + 8)
        var zeroCount = 0
        for byte in rbsp {
            if zeroCount >= 2, byte <= 0x03 {
                escaped.append(0x03)
                zeroCount = 0
            }
            escaped.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        var nal = Data([0x4E, 0x01])
        nal.append(escaped)
        return nal
    }

    private static func makeCompressedSample(
        from source: CMSampleBuffer,
        format: CMFormatDescription,
        bytes: Data
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "HDR10+ block-buffer allocation failed with status \(status)"
            )
        }
        status = bytes.withUnsafeBytes { sourceBytes in
            guard let baseAddress = sourceBytes.baseAddress else {
                return kCMBlockBufferBadLengthParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: bytes.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "HDR10+ block-buffer write failed with status \(status)"
            )
        }
        var timing = CMSampleTimingInfo()
        status = CMSampleBufferGetSampleTimingInfo(
            source,
            at: 0,
            timingInfoOut: &timing
        )
        guard status == noErr else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "HDR10+ sample timing read failed with status \(status)"
            )
        }
        var sampleSize = bytes.count
        var rewritten: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &rewritten
        )
        guard status == noErr, let rewritten else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "HDR10+ sample creation failed with status \(status)"
            )
        }
        CMPropagateAttachments(source, destination: rewritten)
        try copySampleAttachments(from: source, to: rewritten)
        return rewritten
    }

    private static func copySampleAttachments(
        from source: CMSampleBuffer,
        to destination: CMSampleBuffer
    ) throws {
        guard let sourceArray = CMSampleBufferGetSampleAttachmentsArray(
            source,
            createIfNecessary: false
        ) else { return }
        let sourceCount = CFArrayGetCount(sourceArray)
        guard sourceCount == 1,
              let destinationArray = CMSampleBufferGetSampleAttachmentsArray(
                  destination,
                  createIfNecessary: true
              ),
              CFArrayGetCount(destinationArray) == 1 else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "HDR10+ sample attachment cardinality differs"
            )
        }
        let sourceDictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(sourceArray, 0),
            to: CFDictionary.self
        )
        let destinationDictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(destinationArray, 0),
            to: CFMutableDictionary.self
        )
        CFDictionaryApplyFunction(
            sourceDictionary,
            { key, value, context in
                guard let key, let value, let context else { return }
                let dictionary = Unmanaged<CFMutableDictionary>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                CFDictionarySetValue(dictionary, key, value)
            },
            Unmanaged.passUnretained(destinationDictionary).toOpaque()
        )
    }

    private static func removeHEVCEmulationPrevention(
        _ escaped: Data
    ) throws -> Data {
        var rbsp = Data()
        rbsp.reserveCapacity(escaped.count)
        var zeroCount = 0
        var index = escaped.startIndex
        while index < escaped.endIndex {
            let byte = escaped[index]
            if zeroCount >= 2, byte == 0x03 {
                let next = escaped.index(after: index)
                guard next < escaped.endIndex, escaped[next] <= 0x03 else {
                    throw HDRMetadataV4Error.contradictoryMetadata(
                        "invalid HEVC emulation-prevention sequence"
                    )
                }
                zeroCount = 0
                index = next
                continue
            }
            if zeroCount >= 2, byte <= 0x02 {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "unescaped HEVC start-code sequence"
                )
            }
            rbsp.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
            index = escaped.index(after: index)
        }
        return rbsp
    }

    private struct HEVCSEIMessage {
        let type: Int
        let payload: Data
    }

    private static func hdr10PlusPayloads(
        in rbsp: Data
    ) throws -> [HDR10PlusMetadataV4] {
        try hevcSEIMessages(in: rbsp).compactMap { message in
            guard message.type == 4,
                  message.payload.starts(with: [
                    0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04
                  ]) else { return nil }
            return try HDR10PlusMetadataV4(ituTT35Payload: message.payload)
        }
    }

    private static func hevcSEIMessages(
        in rbsp: Data
    ) throws -> [HEVCSEIMessage] {
        guard rbsp.last == 0x80 else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "HEVC SEI RBSP trailing bits differ"
            )
        }
        let messageEnd = rbsp.index(before: rbsp.endIndex)
        var index = rbsp.startIndex
        var result: [HEVCSEIMessage] = []

        func extendedValue(_ label: String) throws -> Int {
            var value = 0
            while index < messageEnd, rbsp[index] == 0xFF {
                let (expanded, overflow) = value.addingReportingOverflow(255)
                guard !overflow else {
                    throw HDRMetadataV4Error.contradictoryMetadata(
                        "HEVC SEI \(label) overflows"
                    )
                }
                value = expanded
                index = rbsp.index(after: index)
            }
            guard index < messageEnd else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "HEVC SEI \(label) is truncated"
                )
            }
            let (expanded, overflow) = value.addingReportingOverflow(
                Int(rbsp[index])
            )
            guard !overflow else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "HEVC SEI \(label) overflows"
                )
            }
            value = expanded
            index = rbsp.index(after: index)
            return value
        }

        while index < messageEnd {
            let payloadType = try extendedValue("payload type")
            let payloadSize = try extendedValue("payload size")
            guard payloadSize <= messageEnd - index else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "HEVC SEI payload is truncated"
                )
            }
            let end = index + payloadSize
            let payload = Data(rbsp[index..<end])
            result.append(HEVCSEIMessage(type: payloadType, payload: payload))
            index = end
        }
        return result
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

struct HDR10PlusPresentationTimeV4: Codable, Comparable, Hashable, Sendable {
    let value: Int64
    let timescale: Int32
    let epoch: Int64

    init(_ time: CMTime) throws {
        guard time.isNumeric,
              !time.flags.contains(.hasBeenRounded),
              time.timescale > 0 else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "dynamic HDR presentation time is not exact and numeric"
            )
        }
        let divisor = Self.greatestCommonDivisor(
            time.value.magnitude,
            UInt64(time.timescale)
        )
        value = time.value / Int64(divisor)
        timescale = time.timescale / Int32(divisor)
        epoch = time.epoch
    }

    var cmTime: CMTime {
        CMTime(
            value: value,
            timescale: timescale,
            flags: .valid,
            epoch: epoch
        )
    }

    static func < (
        lhs: HDR10PlusPresentationTimeV4,
        rhs: HDR10PlusPresentationTimeV4
    ) -> Bool {
        if lhs.epoch != rhs.epoch { return lhs.epoch < rhs.epoch }
        let comparison = CMTimeCompare(lhs.cmTime, rhs.cmTime)
        if comparison != 0 { return comparison < 0 }
        if lhs.value != rhs.value { return lhs.value < rhs.value }
        return lhs.timescale < rhs.timescale
    }

    private static func greatestCommonDivisor(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        var lhs = lhs
        var rhs = rhs
        while rhs != 0 {
            (lhs, rhs) = (rhs, lhs % rhs)
        }
        return max(lhs, 1)
    }
}

struct HDR10PlusPresentationRecordV4: Equatable, Hashable, Sendable {
    let presentationTime: HDR10PlusPresentationTimeV4
    let metadata: HDR10PlusMetadataV4?
}

struct HDR10PlusSegmentLedgerSnapshotV4: Equatable, Sendable {
    private struct IdentityRecord: Codable {
        let presentationTime: HDR10PlusPresentationTimeV4
        let hdr10PlusSHA256: ASHSHA256V4?
    }

    let records: [HDR10PlusPresentationRecordV4]
    let canonicalSHA256: ASHSHA256V4

    init(_ records: [HDR10PlusPresentationRecordV4]) throws {
        let sorted = records.sorted {
            $0.presentationTime < $1.presentationTime
        }
        guard Set(sorted.map(\.presentationTime)).count == sorted.count else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "dynamic HDR ledger contains duplicate presentation times"
            )
        }
        self.records = sorted
        canonicalSHA256 = try ASHCanonicalJSONV4.hash(
            sorted.map {
                IdentityRecord(
                    presentationTime: $0.presentationTime,
                    hdr10PlusSHA256: $0.metadata.map {
                        ASHSHA256V4(rawData: $0.ituTT35Payload)
                    }
                )
            },
            domain: "ash-hdr10plus-presentation-ledger-v4"
        )
    }
}

actor HDR10PlusSegmentLedgerV4 {
    private let sourceSnapshot: HDR10PlusSegmentLedgerSnapshotV4
    private let maximumOutputRecordCount: Int
    private var unconsumedSource: [
        HDR10PlusPresentationTimeV4: HDR10PlusMetadataV4?
    ]
    private var outputRecords: [
        HDR10PlusPresentationTimeV4: HDR10PlusMetadataV4?
    ] = [:]

    init(
        sourceRecords: [HDR10PlusPresentationRecordV4],
        maximumInputFrames: Int,
        maximumOutputFramesPerInput: Int
    ) throws {
        guard maximumInputFrames > 0,
              maximumOutputFramesPerInput > 0,
              sourceRecords.count <= maximumInputFrames else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "dynamic HDR source ledger exceeds its segment bound"
            )
        }
        let (maximumOutputRecordCount, overflow) = maximumInputFrames
            .multipliedReportingOverflow(by: maximumOutputFramesPerInput)
        guard !overflow, maximumOutputRecordCount > 0 else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "dynamic HDR output ledger bound overflows"
            )
        }
        let snapshot = try HDR10PlusSegmentLedgerSnapshotV4(sourceRecords)
        self.sourceSnapshot = snapshot
        self.maximumOutputRecordCount = maximumOutputRecordCount
        unconsumedSource = Dictionary(
            uniqueKeysWithValues: snapshot.records.map {
                ($0.presentationTime, $0.metadata)
            }
        )
    }

    func consumeSource(
        presentationTime: CMTime,
        decodedMetadata: HDRDynamicMetadataV4?
    ) throws -> HDR10PlusMetadataV4? {
        if decodedMetadata?.postDecodeProcessing != nil {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "post-decode metadata has no HEVC/MOV preservation contract"
            )
        }
        let key = try HDR10PlusPresentationTimeV4(presentationTime)
        guard let retained = unconsumedSource.removeValue(forKey: key) else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "decoded source presentation time is missing or duplicated"
            )
        }
        let expected = retained
        if let expected, let decoded = decodedMetadata?.hdr10Plus,
           expected != decoded {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "decoded and compressed HDR10+ metadata differ"
            )
        }
        if expected == nil, decodedMetadata?.hdr10Plus != nil {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "decoded HDR10+ metadata has no compressed source record"
            )
        }
        return expected ?? decodedMetadata?.hdr10Plus
    }

    func recordOutput(
        presentationTime: CMTime,
        metadata: HDR10PlusMetadataV4?
    ) throws {
        guard outputRecords.count < maximumOutputRecordCount else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "dynamic HDR output ledger exceeds its segment bound"
            )
        }
        let key = try HDR10PlusPresentationTimeV4(presentationTime)
        guard outputRecords.updateValue(metadata, forKey: key) == nil else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "dynamic HDR output presentation time is duplicated"
            )
        }
    }

    func seal(
        expectedSourceCount: Int,
        expectedOutputCount: Int
    ) throws -> (
        source: HDR10PlusSegmentLedgerSnapshotV4,
        output: HDR10PlusSegmentLedgerSnapshotV4
    ) {
        guard unconsumedSource.isEmpty,
              sourceSnapshot.records.count == expectedSourceCount else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "compressed and decoded source presentation domains differ"
            )
        }
        guard outputRecords.count == expectedOutputCount else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "dynamic HDR output presentation domain differs"
            )
        }
        let output = try HDR10PlusSegmentLedgerSnapshotV4(
            outputRecords.map {
                HDR10PlusPresentationRecordV4(
                    presentationTime: $0.key,
                    metadata: $0.value
                )
            }
        )
        return (sourceSnapshot, output)
    }
}
