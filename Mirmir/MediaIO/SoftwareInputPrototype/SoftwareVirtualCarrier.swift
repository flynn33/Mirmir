import AVFoundation
import Foundation
import ObjectiveC
import UniformTypeIdentifiers

private final class SoftwareCarrierCancellation: NativeMediaInputCancellationV4, @unchecked Sendable {
    private let lock = NSLock()
    private var current: (any NativeMediaInputCancellationV4)?
    init(_ current: (any NativeMediaInputCancellationV4)?) { self.current = current }
    func check() throws {
        lock.lock(); let value = current; lock.unlock()
        try value?.check()
    }
    func bind(_ value: (any NativeMediaInputCancellationV4)?) throws {
        try check()
        guard let value else { return }
        lock.lock(); current = value; lock.unlock()
    }
}

/// Private source-snapshot prototype. Original facts are never inferred from
/// this MOV: it delivers bounded working video, explicitly decoded audio,
/// or authenticated original AAC/PCM packets with a separately bound policy.
struct SoftwarePresentationVideoPolicy: Codable, Equatable, Sendable {
    let sourceOrdinal: Int32
    let originalSourceSHA256: ASHSHA256V4
    let originalVideoSHA256: ASHSHA256V4
    let sourceMatrix: Int32
    let sourceFullRange: Bool
    let sourceChromaLocation: Int32
    let qualifiedUnspecified8BitRange: Bool
    let destinationBytesPerRow: Int
    let outputFormat: String
    let converter: String
    let parameters: [OriginalSoftwareDecodeParameter]
}

final class SoftwareVirtualCarrier: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private static var associationKey: UInt8 = 0
    private let context: OriginalSoftwareMediaContext
    private let cancellation: SoftwareCarrierCancellation
    private let queue = DispatchQueue(label: "mirmir.private.software.carrier", qos: .utility)
    private let tracks: [CarrierTrack]
    private let header: Data
    private let extent: Int64
    private var servedBytes: Int64 = 0
    private var requestCount: Int64 = 0
    private var maximumResponse = 0
    let presentationPolicy: SoftwarePresentationVideoPolicy?
    private var referenceReads: Int64 = 0
    private var referenceControlCount: Int64 = 0
    private var emptyControlCount: Int64 = 0
    private var permanentControlCount: Int64 = 0
    private var referenceControlKeys = Set<String>()
    private let readerEmptyMarkers = NSMapTable<AVAssetReader, NSNumber>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    static func make(url: URL, cancellation: (any NativeMediaInputCancellationV4)? = nil, sourceIdentity: ASHStreamingFileIdentityV4? = nil) async throws -> AVURLAsset {
        let linkedCancellation = SoftwareCarrierCancellation(cancellation)
        let raw = try await OriginalSoftwareMediaContext.make(url: url, cancellation: linkedCancellation, sourceIdentity: sourceIdentity)
        guard let state = raw.typedProjection.state else { throw ProbeFailure("missing original state") }
        guard raw.sourceFacts.streams.filter({ $0.mediaType == 0 }).count == 1,
              raw.sourceFacts.streams.filter({ $0.mediaType == 1 }).count <= 1 else {
            throw ProbeFailure("private software workflow qualifies one video and at most one audio track; original alternate-track migration not qualified")
        }
        let workingOffset = try Self.sharedWorkingOffset(raw)
        let policies = try raw.sourceFacts.streams.filter { $0.mediaType == 0 }.map { stream in
            guard Int(stream.ordinal) < raw.timings.count,
                  let decodedFormat = raw.timings[Int(stream.ordinal)].decodedPixelFormat,
                  let video = state.tracks.first(where: { $0.identity.ordinal == UInt32(stream.ordinal) })?.video,
                  (8...16).contains(video.pixel.bitDepth), video.pixel.alphaModel == .none,
                  !raw.timings[Int(stream.ordinal)].hasHDRSideData,
                  stream.width > 0, stream.height > 0 else {
                throw ProbeFailure("private carrier requires qualified opaque even-raster working layout")
            }
            let rgb = video.pixel.chromaSubsampling == .rgb
            let destinationColor: CanonicalColorStateV4
            if rgb {
                guard video.pixel.bitDepth == 8, stream.width % 2 == 0, stream.height % 2 == 0,
                      mirmir_rgb8_layout_supported(decodedFormat) != 0,
                      video.pixel.range == .full, stream.colorRange == 2,
                      video.color.matrix == "Identity", stream.matrix == 0,
                      ["ITU_R_709_2", "sRGB"].contains(video.color.transferFunction),
                      video.color.masteringDisplay == nil, video.color.contentLightLevel == nil,
                      video.color.ambientViewingEnvironment == nil,
                      video.color.dynamicHDRMetadata.isEmpty else {
                    throw ProbeFailure("unqualified original RGB signal/color/range conversion")
                }
                destinationColor = OriginalSoftwareWorkingVideoPolicy.destinationColor(for: video)
            } else {
                guard mib_biplanar_layout_supported(decodedFormat) != 0,
                      [.yuv420, .yuv422, .yuv444].contains(video.pixel.chromaSubsampling),
                      !raw.timings[Int(stream.ordinal)].hasHDRSideData,
                      ["ITU_R_709_2", "sRGB"].contains(video.color.transferFunction),
                      video.color.masteringDisplay == nil, video.color.contentLightLevel == nil,
                      video.color.dynamicHDRMetadata.isEmpty else {
                    throw ProbeFailure("private carrier supports qualified planar YUV or explicit RGB conversion only")
                }
                destinationColor = video.color
            }
            let parameters = OriginalSoftwareWorkingVideoPolicy.parameters(for: video,
                qualifiesUnspecifiedRange: OriginalSoftwareWorkingVideoPolicy.qualifiesUnspecified8BitRange(
                    stream: stream, timeline: raw.timings[Int(stream.ordinal)], video: video))
            return OriginalSoftwareWorkingVideoPolicy(
                sourceOrdinal: stream.ordinal, sourceVideoSHA256: try raw.sourceVideoSHA256(ordinal: stream.ordinal),
                destinationFormatID: OriginalSoftwareWorkingVideoPolicy.destinationFormat(for: video),
                destinationRaster: video.encodedRaster, destinationBitDepth: OriginalSoftwareWorkingVideoPolicy.destinationDepth(for: video),
                destinationRange: video.pixel.range, destinationChroma: .yuv420,
                destinationSiting: try OriginalSoftwareWorkingVideoPolicy.destinationSiting(for: video),
                destinationColor: destinationColor,
                converterID: rgb ? "mirmir-rgb8-rational420-raw-biplanar-delivery" : "mirmir-opaque-yuv-rational420-raw-biplanar-delivery",
                converterVersion: "2", parameters: parameters
            )
        }
        let bound = try raw.bindingWorkingDecodePolicy(.init(
            carrierID: "mirmir-private-on-demand-working-mov", carrierVersion: "4",
            parameters: OriginalSoftwareWorkingDecodePolicy.parameters(workingOffset: workingOffset), tracks: policies))
        let loader = try SoftwareVirtualCarrier(context: bound, workingOffset: workingOffset, cancellation: linkedCancellation)
        let asset = AVURLAsset(url: URL(string: "mirmir-software-source://\(UUID().uuidString)/source.mov")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        try bound.associate(to: asset)
        objc_setAssociatedObject(asset, &associationKey, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    static func makePresentation(from processingAsset: AVURLAsset,
                                 cancellation: (any NativeMediaInputCancellationV4)? = nil) throws -> AVURLAsset {
        guard let context = OriginalSoftwareMediaContext.associated(with: processingAsset),
              context.workingDecodePolicy != nil,
              let source = context.sourceFacts.streams.first(where: { $0.mediaType == 0 }),
              let video = context.typedProjection.state?.tracks.first(where: {
                  $0.identity.ordinal == UInt32(source.ordinal)
              })?.video,
              video.scan.fieldCount == 1, video.pixel.alphaModel == .none,
              ["ITU_R_709_2", "sRGB"].contains(video.color.transferFunction),
              video.color.masteringDisplay == nil, video.color.contentLightLevel == nil,
              video.color.dynamicHDRMetadata.isEmpty,
              let matrix = ["Identity": Int32(0), "ITU_R_709_2": 1,
                            "ITU_R_601_4": 6, "ITU_R_2020": 9][video.color.matrix] else {
            throw ProbeFailure("unqualified original presentation signal")
        }
        try context.originalProbe.checkCancellation()
        try context.originalProbe.file.verifyUnchanged(url: context.originalProbe.url)
        let location: Int32
        switch video.pixel.chromaSiting {
        case .left: location = 1
        case .center: location = 2
        case .topLeft: location = 3
        case .top: location = 4
        case .bottomLeft: location = 5
        case .bottom: location = 6
        case .notApplicable: location = 0
        case .unknown: throw ProbeFailure("unknown original presentation phase")
        }
        var nativeBuffer: CVPixelBuffer?
        let bufferStatus = CVPixelBufferCreate(kCFAllocatorDefault, Int(source.width), Int(source.height),
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &nativeBuffer)
        guard bufferStatus == kCVReturnSuccess, let nativeBuffer else {
            throw ProbeFailure("native presentation stride allocation failed")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(nativeBuffer)
        guard rowBytes >= Int(source.width) * 4,
              rowBytes <= 64 * 1024 * 1024 / Int(source.height) else {
            throw ProbeFailure("native presentation stride exceeds frame bound")
        }
        let policy = SoftwarePresentationVideoPolicy(sourceOrdinal: source.ordinal,
            originalSourceSHA256: context.sourceFacts.sourceHash,
            originalVideoSHA256: try context.sourceVideoSHA256(ordinal: source.ordinal),
            sourceMatrix: matrix, sourceFullRange: video.pixel.range == .full,
            sourceChromaLocation: location,
            qualifiedUnspecified8BitRange: OriginalSoftwareWorkingVideoPolicy.qualifiesUnspecified8BitRange(
                stream: source, timeline: context.timings[Int(source.ordinal)], video: video),
            destinationBytesPerRow: rowBytes, outputFormat: "BGRA8_opaque_full_range", converter: "ffmpeg8.1.2-strict-scalar-swscale-presentation-v1",
            parameters: [.init(key: "alpha", value: "opaque255"),
                .init(key: "chroma", value: "explicit original source horizontal/vertical chroma location in luma-grid/256; full chroma interpolation"),
                .init(key: "color", value: "source-declared or separately qualified matrix/range; same primaries and transfer; no tone mapping or primary transform"),
                .init(key: "delivery", value: "native packed BGRA with exact visible raster and qualified native IOSurface stride; deterministic zero row padding; display only; never a processing source"),
                .init(key: "flags", value: "bilinear accurate_rnd bitexact full_chroma_int dither_none threads1"),
                .init(key: "layout", value: "Y210BE/Y212BE/Y216BE losslessly unpacked to identical component depth and422coordinates in planar little-endian storage; no quantization or chroma reduction")])
        let linkedCancellation = SoftwareCarrierCancellation(cancellation)
        let loader = try SoftwareVirtualCarrier(context: context,
            workingOffset: sharedWorkingOffset(context), cancellation: linkedCancellation, presentationPolicy: policy)
        let asset = AVURLAsset(url: URL(string: "mirmir-software-presentation://\(UUID().uuidString)/source.mov")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        // A presentation carrier deliberately has no associated processing context.
        objc_setAssociatedObject(asset, &associationKey, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        try ASHCanonicalJSONV4.encode(policy).write(to: context.evidenceDirectory.appendingPathComponent("presentation-policy.json"))
        return asset
    }

    static func presentationFrameTime(in asset: AVAsset, preferredSeconds: Double) throws -> CMTime? {
        guard let loader = objc_getAssociatedObject(asset, &associationKey) as? SoftwareVirtualCarrier,
              loader.presentationPolicy != nil else { return nil }
        return try loader.queue.sync {
            try loader.context.originalProbe.checkCancellation()
            guard let times = loader.tracks.first(where: { $0.stream.mediaType == 0 })?.videoPresentationTimes,
                  let first = times.first else { throw ProbeFailure("presentation frame clock missing") }
            // The seconds value is a presentation hint; return an authentic exact frame time.
            let requested = preferredSeconds.isFinite ? max(0, preferredSeconds) : 0
            var lower = 0, upper = times.count
            while lower < upper {
                let mid = lower + (upper - lower) / 2
                let seconds = Double(times[mid].numerator) / Double(times[mid].denominator)
                if seconds <= requested { lower = mid + 1 } else { upper = mid }
            }
            return try cm(lower == 0 ? first : times[lower - 1])
        }
    }

    static func presentation(_ asset: AVAsset, belongsTo processing: AVAsset) -> Bool {
        guard let loader = objc_getAssociatedObject(asset, &associationKey) as? SoftwareVirtualCarrier,
              loader.presentationPolicy != nil else { return false }
        return loader.context === OriginalSoftwareMediaContext.associated(with: processing)
    }

    static func presentationPolicy(in asset: AVAsset) -> SoftwarePresentationVideoPolicy? {
        (objc_getAssociatedObject(asset, &associationKey) as? SoftwareVirtualCarrier)?.presentationPolicy
    }

    static func reuse(_ asset: AVAsset, cancellation: (any NativeMediaInputCancellationV4)?) throws -> Bool {
        guard let loader = objc_getAssociatedObject(asset, &associationKey) as? SoftwareVirtualCarrier else { return false }
        do { try loader.cancellation.bind(cancellation); try loader.context.originalProbe.checkCancellation(); return true }
        catch is CancellationError { return false }
    }

    static func referenceData(for sample: CMSampleBuffer, asset: AVAsset) throws -> Data {
        try resolveReference(for: sample, asset: asset).data
    }

    static func resolveReference(for sample: CMSampleBuffer, asset: AVAsset, allowedFrames: Range<Int>? = nil) throws -> (data: Data, presentation: CMTime, mediaToWorkingOffset: CMTime) {
        guard let carrier = objc_getAssociatedObject(asset, &associationKey) as? SoftwareVirtualCarrier,
              carrier.presentationPolicy == nil,
              let asset = asset as? AVURLAsset,
              let url = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_SampleReferenceURL,
                attachmentModeOut: nil) as? URL, url == asset.url,
              let number = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_SampleReferenceByteOffset,
                attachmentModeOut: nil) as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
              let offset = Int64(number.stringValue), offset >= 0,
              CMSampleBufferGetNumSamples(sample) == 1,
              CMSampleBufferGetImageBuffer(sample) == nil,
              CMSampleBufferGetDataBuffer(sample) == nil else {
            throw ProbeFailure("working sample reference is not bound to this carrier")
        }
        let size = CMSampleBufferGetTotalSampleSize(sample)
        guard size > 0, size <= 64 * 1024 * 1024 else { throw ProbeFailure("working sample reference size") }
        return try carrier.queue.sync {
            try carrier.cancellation.check()
            guard let track = carrier.tracks.first(where: {
                $0.stream.mediaType == 0 && offset >= $0.payloadOffset
                    && offset < $0.payloadOffset + $0.bytes
            }) else { throw ProbeFailure("working reference is not a qualified raw video sample") }
            let relative = offset - track.payloadOffset, index = Int(relative / Int64(track.frameBytes))
            guard index < track.chunks.count, relative == track.chunks[index].byteOffset,
                  size == track.chunks[index].byteCount,
                  allowedFrames?.contains(index) ?? true else {
                throw ProbeFailure("working reference is outside its authenticated frame scope or sample extent")
            }
            let selectedClock = CMSampleBufferGetPresentationTimeStamp(sample)
            let targetPresentation = try cm(track.videoPresentationTimes[index])
            let mediaPresentation = try cm(track.videoPresentationTimes[index].subtracting(track.start))
            guard CMTimeCompare(selectedClock, mediaPresentation) == 0 else {
                throw ProbeFailure("working reference media presentation differs: frame=\(index), observed=\(selectedClock), expectedMedia=\(mediaPresentation), workingTarget=\(targetPresentation)")
            }
            let duration = CMSampleBufferGetDuration(sample)
            if duration.isNumeric, duration.value > 0 {
                guard CMTimeCompare(duration, try cm(track.durations[index])) == 0 else {
                    throw ProbeFailure("working reference media duration differs")
                }
            } else if duration.isValid { throw ProbeFailure("working reference duration state is invalid") }
            let data = try track.read(relativeOffset: relative, count: size)
            guard data.count == size else { throw ProbeFailure("working reference did not resolve the full sample") }
            carrier.referenceReads += 1
            return (data, targetPresentation, try cm(track.start))
        }
    }

    static func referenceReadCount(in asset: AVAsset) throws -> Int64 {
        guard let carrier = objc_getAssociatedObject(asset, &associationKey) as? SoftwareVirtualCarrier else {
            throw ProbeFailure("working carrier reference owner missing")
        }
        return carrier.queue.sync { carrier.referenceReads }
    }

    static func expectedEdits(in asset: AVAsset, sourceOrdinal: Int32) throws -> [MediaTrackEditV4] {
        guard let carrier = objc_getAssociatedObject(asset, &associationKey) as? SoftwareVirtualCarrier else {
            throw ProbeFailure("working carrier edit owner missing")
        }
        return try carrier.queue.sync {
            guard let track = carrier.tracks.first(where: { $0.stream.ordinal == sourceOrdinal }) else {
                throw ProbeFailure("working carrier edit track missing")
            }
            var result: [MediaTrackEditV4] = []
            if track.start > .zero {
                result.append(try MediaTrackEditV4(ordinal: 0, source: nil,
                    target: MediaExactTimeRangeV4(start: .zero, duration: track.start), isEmpty: true))
            }
            result.append(try MediaTrackEditV4(ordinal: UInt32(result.count),
                source: MediaExactTimeRangeV4(start: track.mediaStart, duration: track.duration),
                target: MediaExactTimeRangeV4(start: track.start, duration: track.duration), isEmpty: false))
            return result
        }
    }

    static func accountReferenceControl(_ sample: CMSampleBuffer, asset: AVAsset, reader: AVAssetReader) throws {
        guard let carrier = objc_getAssociatedObject(asset, &associationKey) as? SoftwareVirtualCarrier,
              CMSampleBufferGetNumSamples(sample) == 0, CMSampleBufferGetTotalSampleSize(sample) == 0,
              CMSampleBufferGetImageBuffer(sample) == nil, CMSampleBufferGetDataBuffer(sample) == nil,
              CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_SampleReferenceURL, attachmentModeOut: nil) == nil,
              CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_SampleReferenceByteOffset, attachmentModeOut: nil) == nil else {
            throw ProbeFailure("zero-sample working control carries unauthorized media/reference data")
        }
        try carrier.queue.sync {
            try carrier.cancellation.check()
            let empty = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_EmptyMedia, attachmentModeOut: nil) as? Bool == true
            let permanent = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_PermanentEmptyMedia, attachmentModeOut: nil) as? Bool == true
            guard !permanent || empty else { throw ProbeFailure("permanent empty marker lacks its empty-media flag") }
            if empty && !permanent {
                guard let track = carrier.tracks.first(where: { $0.stream.mediaType == 0 }) else {
                    throw ProbeFailure("working empty-marker track missing")
                }
                let presentation = CMSampleBufferGetOutputPresentationTimeStamp(sample)
                let duration = CMSampleBufferGetOutputDuration(sample)
                let leadingDuration = try cm(track.start)
                let leading = track.start > .zero && CMTimeCompare(presentation, .zero) == 0
                    && (CMTimeCompare(duration, .zero) == 0 || CMTimeCompare(duration, leadingDuration) == 0)
                let selectionBoundary = CMTimeCompare(duration, .zero) == 0
                    && CMTimeCompare(presentation, reader.timeRange.start) == 0
                guard leading || selectionBoundary,
                      carrier.readerEmptyMarkers.object(forKey: reader) == nil else {
                    throw ProbeFailure("unsupported additional/internal empty marker: outputPTS=\(presentation), duration=\(duration)")
                }
                carrier.readerEmptyMarkers.setObject(1, forKey: reader)
            }
            carrier.referenceControlCount += 1
            if empty { carrier.emptyControlCount += 1 }
            if permanent { carrier.permanentControlCount += 1 }
            for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
                if let values = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault,
                    target: sample, attachmentMode: mode) as? [String: Any] {
                    carrier.referenceControlKeys.formUnion(values.keys)
                }
            }
            let report: [String: Any] = ["zeroSampleControlEvents": carrier.referenceControlCount,
                "emptyMarkers": carrier.emptyControlCount, "permanentEndMarkers": carrier.permanentControlCount,
                "observedControlKeys": carrier.referenceControlKeys.sorted(),
                "rawReferenceReads": carrier.referenceReads, "controlsReadNoPixelPayload": true]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: carrier.context.evidenceDirectory.appendingPathComponent(carrier.presentationPolicy == nil
                    ? "working-reference-controls.json" : "presentation-reference-controls.json"), options: .atomic)
        }
    }

    static func sharedWorkingOffset(_ context: OriginalSoftwareMediaContext) throws -> ExactRationalV4 {
        guard let first = try context.timings.compactMap(\.selectedStart).map(context.sharedOrigin.normalize).min() else {
            throw ProbeFailure("missing exact selected working origin")
        }
        return try first.negated()
    }

    private init(context: OriginalSoftwareMediaContext, workingOffset: ExactRationalV4, cancellation: SoftwareCarrierCancellation, presentationPolicy: SoftwarePresentationVideoPolicy? = nil) throws {
        self.presentationPolicy = presentationPolicy
        self.context = context; self.cancellation = cancellation
        guard context.sourceFacts.streams.count <= 8 else { throw ProbeFailure("private carrier stream limit") }
        var result: [CarrierTrack] = []
        for stream in context.sourceFacts.streams {
            guard stream.mediaType == 0 || stream.mediaType == 1 else { throw ProbeFailure("unrepresented original source kind") }
            let url = context.evidenceDirectory.appendingPathComponent("stream-\(stream.ordinal)-frames.jsonl")
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // Explicit prototype metadata bound. This stores timing/offset facts,
            // never decoded movie payloads; longer inputs fail rather than grow.
            let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 16 * 1024 * 1024 else { throw ProbeFailure("private carrier timing metadata limit") }
            let frames = try data.split(separator: 10).map { try JSONDecoder().decode(FrameFact.self, from: Data($0)) }
            result.append(try CarrierTrack(context: context, stream: stream, frames: frames, workingOffset: workingOffset, presentationPolicy: presentationPolicy))
        }
        self.tracks = result
        let movie = try CarrierMOV.make(tracks: result)
        header = movie.header; extent = movie.extent
        super.init()
        let report: [String: Any] = ["logicalBytes": extent, "headerBytes": header.count,
            "tracks": result.map { ["sourceOrdinal": $0.stream.ordinal, "chunks": $0.chunks.count,
                                    "logicalBytes": $0.bytes, "start": $0.start.description, "duration": $0.duration.description] }]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: context.evidenceDirectory.appendingPathComponent(presentationPolicy == nil ? "carrier.json" : "presentation-carrier.json"))
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        do {
            try context.originalProbe.checkCancellation()
            requestCount += 1
            if let info = request.contentInformationRequest {
                info.contentType = UTType.quickTimeMovie.identifier
                info.contentLength = extent
                info.isByteRangeAccessSupported = true
                info.isEntireLengthAvailableOnDemand = true
            }
            if let data = request.dataRequest {
                var offset = data.currentOffset > 0 ? data.currentOffset : data.requestedOffset
                guard offset >= 0, offset <= extent, data.requestedLength >= 0 else { throw ProbeFailure("carrier request outside resource") }
                let (endRequested, overflow) = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
                guard !overflow else { throw ProbeFailure("carrier request overflow") }
                let end = data.requestsAllDataToEndOfResource ? extent : min(extent, endRequested)
                while offset < end {
                    if request.isCancelled { throw CancellationError() }
                    try context.originalProbe.checkCancellation()
                    let count = Int(min(65_536, end - offset))
                    let chunk = try read(offset: offset, count: count)
                    guard !chunk.isEmpty else { throw ProbeFailure("carrier premature EOF") }
                    data.respond(with: chunk); offset += Int64(chunk.count)
                    servedBytes += Int64(chunk.count); maximumResponse = max(maximumResponse, chunk.count)
                }
            }
            request.finishLoading()
        } catch { request.finishLoading(with: error) }
        return true
    }

    private func read(offset: Int64, count: Int) throws -> Data {
        if offset < header.count { return header.subdata(in: Int(offset)..<min(header.count, Int(offset) + count)) }
        for track in tracks where offset >= track.payloadOffset && offset < track.payloadOffset + track.bytes {
            return try track.read(relativeOffset: offset - track.payloadOffset, count: count)
        }
        throw ProbeFailure("carrier unmapped logical range")
    }
}

private final class CarrierTrack {
    struct Chunk { let frame: Int64; let byteOffset: Int64; let byteCount: Int; let samples: Int; let audibleOffset: Int }
    let context: OriginalSoftwareMediaContext
    let stream: OriginalStream
    let chunks: [Chunk]
    let durations: [ExactRationalV4]
    let videoPresentationTimes: [ExactRationalV4]
    let start: ExactRationalV4
    let duration: ExactRationalV4
    let bytes: Int64
    let frameBytes: Int
    let color: CanonicalColorStateV4?
    let fullRange: Bool
    let rgbConversion: Bool
    let presentationPolicy: SoftwarePresentationVideoPolicy?
    let workingDepth: UInt8
    let interpretedUnspecifiedRange: Bool
    let workingFormat: String?
    let packetAudio: Bool
    let compressedAudio: Bool
    let mediaStart: ExactRationalV4
    let mediaDuration: ExactRationalV4
    let packetHashes: [ASHSHA256V4]
    var payloadOffset: Int64 = 0
    private var cursor: OpaquePointer?
    private var currentFrame: Int64 = -1
    private var cachedChunk: Int = -1
    private var cached = Data()

    init(context: OriginalSoftwareMediaContext, stream: OriginalStream, frames: [FrameFact], workingOffset: ExactRationalV4, presentationPolicy: SoftwarePresentationVideoPolicy? = nil) throws {
        self.presentationPolicy = stream.mediaType == 0 ? presentationPolicy : nil
        self.context = context; self.stream = stream
        guard !frames.isEmpty, Int(stream.ordinal) < context.timings.count else { throw ProbeFailure("carrier timing inventory") }
        let timeline = context.timings[Int(stream.ordinal)]
        guard let sourceStart = timeline.selectedStart, let sourceEnd = timeline.selectedEnd else { throw ProbeFailure("missing selected carrier timing") }
        start = try context.sharedOrigin.normalize(sourceStart).adding(workingOffset)
        duration = try sourceEnd.subtracting(sourceStart)
        videoPresentationTimes = stream.mediaType == 0 ? try frames.map {
            guard let presentation = $0.selectedPresentation else { throw ProbeFailure("raw video source presentation missing") }
            return try context.sharedOrigin.normalize(presentation).adding(workingOffset)
        } : []
        guard start >= .zero, duration.isPositive else { throw ProbeFailure("carrier negative start or empty extent") }
        let sourceVideo = context.typedProjection.state?.tracks.first { $0.identity.ordinal == UInt32(stream.ordinal) }?.video
        let workingVideo = context.workingDecodePolicy?.tracks.first { $0.sourceOrdinal == stream.ordinal }
        color = workingVideo?.destinationColor
        fullRange = workingVideo?.destinationRange == .full
        rgbConversion = sourceVideo?.pixel.chromaSubsampling == .rgb
        workingDepth = workingVideo?.destinationBitDepth ?? 8
        workingFormat = workingVideo?.destinationFormatID
        interpretedUnspecifiedRange = sourceVideo.map {
            OriginalSoftwareWorkingVideoPolicy.qualifiesUnspecified8BitRange(stream: stream,
                timeline: timeline, video: $0)
        } ?? false
        let canPreserveAAC = stream.codecName == "aac" && stream.profile == 1
            && stream.sampleRate > 0 && stream.sampleRate <= 65535 && stream.frameSize == 1024
            && !stream.extradata.isEmpty && stream.extradata.count <= 64
            && timeline.frameCount == timeline.packetCount
            && timeline.skipEnd == 0 && timeline.skipStart <= 1024
            && frames.enumerated().allSatisfy { index, frame in
                frame.sourcePacketOrdinal == Int64(index) && frame.decodedSamples == 1024
                    && frame.skipEnd == 0 && frame.audibleOffset + frame.audibleSamples == 1024
            }
        let canPreservePCM = stream.codecName == "pcm_s16le"
            && stream.codedDepth == 16 && stream.initialPadding == 0
            && stream.trailingPadding == 0 && timeline.skipStart == 0 && timeline.skipEnd == 0
        packetAudio = stream.mediaType == 1 && (canPreserveAAC || canPreservePCM)
        compressedAudio = packetAudio && canPreserveAAC
        if stream.mediaType == 0 {
            mediaStart = .zero; mediaDuration = duration; packetHashes = []
            if let presentationPolicy = self.presentationPolicy { frameBytes = presentationPolicy.destinationBytesPerRow * Int(stream.height) }
            else {
                let width = Int(stream.width), height = Int(stream.height)
                frameBytes = 16 + (width * height + ((width + 1) / 2) * ((height + 1) / 2) * 2) * (workingDepth == 8 ? 1 : 2)
            }
            guard frameBytes > 0, frameBytes <= 64 * 1024 * 1024 else { throw ProbeFailure("carrier frame bound") }
            var d: [ExactRationalV4] = []
            for i in frames.indices {
                guard frames[i].ordinal == Int64(i), let p = frames[i].selectedPresentation else { throw ProbeFailure("carrier frame ordinal/PTS") }
                let end = i + 1 < frames.count ? frames[i + 1].selectedPresentation : sourceEnd
                guard let end else { throw ProbeFailure("carrier video duration unknown") }
                let step = try end.subtracting(p)
                guard step.isPositive else { throw ProbeFailure("carrier frame duration nonpositive") }
                d.append(step)
            }
            durations = d
            let bytesPerFrame = frameBytes
            chunks = frames.enumerated().map { Chunk(frame: $0.element.ordinal, byteOffset: Int64($0.offset * bytesPerFrame), byteCount: bytesPerFrame, samples: 1, audibleOffset: 0) }
            bytes = Int64(frames.count) * Int64(frameBytes)
        } else if packetAudio {
            guard stream.channels == 1 || stream.channels == 2, stream.sampleRate > 0 else {
                throw ProbeFailure("original packet carrier audio layout unsupported")
            }
            let factsURL = context.evidenceDirectory.appendingPathComponent("stream-\(stream.ordinal)-packets.jsonl")
            let factsHandle = try FileHandle(forReadingFrom: factsURL)
            defer { try? factsHandle.close() }
            let data = try factsHandle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 16 * 1024 * 1024,
                  ASHSHA256V4(rawData: data) == timeline.packetFactsSHA256 else {
                throw ProbeFailure("original audio packet facts authentication")
            }
            let facts = try data.split(separator: 10).map { try JSONDecoder().decode(PacketFact.self, from: Data($0)) }
            var sourceCursor: OpaquePointer?; var error = MIBError()
            try check(mib_cursor_open(context.originalProbe.source, stream.ordinal, 0, &sourceCursor, &error), error)
            defer { mib_cursor_close(&sourceCursor) }
            var chunks: [Chunk] = [], hashes: [ASHSHA256V4] = [], deltas: [ExactRationalV4] = []
            var offset: Int64 = 0, sampleCount: Int64 = 0
            while true {
                try context.originalProbe.checkCancellation()
                var packet = MIBPacket()
                let status = mib_next_packet(sourceCursor, &packet, &error); try check(status, error)
                if status == 0 { break }
                let index = chunks.count
                guard index < facts.count, packet.identity.ordinal_valid != 0,
                      packet.identity.ordinal == Int64(index), facts[index].ordinal == Int64(index),
                      packet.bytes.size > 0, packet.bytes.size <= 16 * 1024 * 1024,
                      let pointer = packet.bytes.data else { throw ProbeFailure("original audio packet inventory changed") }
                let payload = Data(bytes: pointer, count: packet.bytes.size)
                guard ASHSHA256V4(rawData: payload) == facts[index].payloadSHA256 else {
                    throw ProbeFailure("original audio packet payload changed")
                }
                let samples: Int
                if canPreserveAAC { samples = 1024 }
                else {
                    guard payload.count % (Int(stream.channels) * 2) == 0 else { throw ProbeFailure("original PCM packet alignment") }
                    samples = payload.count / (Int(stream.channels) * 2)
                }
                guard samples > 0 else { throw ProbeFailure("empty original audio packet") }
                chunks.append(Chunk(frame: Int64(index), byteOffset: offset,
                    byteCount: payload.count, samples: canPreserveAAC ? 1 : samples, audibleOffset: 0))
                hashes.append(facts[index].payloadSHA256)
                deltas.append(try ExactRationalV4(Int64(samples), Int64(stream.sampleRate)))
                sampleCount += Int64(samples); offset += Int64(payload.count)
            }
            guard chunks.count == facts.count, Int64(chunks.count) == timeline.packetCount,
                  sampleCount - timeline.skipStart - timeline.skipEnd == timeline.audibleSamples else {
                throw ProbeFailure("original packet audio changes audible sample count")
            }
            self.chunks = chunks; bytes = offset; packetHashes = hashes
            frameBytes = canPreserveAAC ? 0 : Int(stream.channels) * 2
            durations = canPreserveAAC ? deltas : []
            mediaStart = try ExactRationalV4(timeline.skipStart, Int64(stream.sampleRate))
            mediaDuration = try ExactRationalV4(sampleCount, Int64(stream.sampleRate))
        } else {
            mediaStart = .zero; mediaDuration = duration; packetHashes = []
            let mono = stream.channels == 1 && ((stream.channelOrder == 1 && stream.channelMask == "4") || (stream.channelOrder == 0 && stream.channelMask == "0"))
            let stereo = stream.channels == 2 && stream.channelOrder == 1 && stream.channelMask == "3"
            guard stream.sampleRate > 0, mono || stereo else { throw ProbeFailure("unqualified carrier audio channel layout") }
            frameBytes = Int(stream.channels) * 4
            var chunks: [Chunk] = []; var offset: Int64 = 0
            for f in frames where f.audibleSamples > 0 {
                let count = Int(f.audibleSamples) * frameBytes
                chunks.append(Chunk(frame: f.ordinal, byteOffset: offset, byteCount: count, samples: Int(f.audibleSamples), audibleOffset: Int(f.audibleOffset)))
                offset += Int64(count)
            }
            self.chunks = chunks; bytes = offset; durations = []
            guard try ExactRationalV4(Int64(chunks.reduce(0) { $0 + $1.samples }), Int64(stream.sampleRate)) == duration else { throw ProbeFailure("carrier audible extent mismatch") }
        }
        guard !chunks.isEmpty else { throw ProbeFailure("carrier empty track") }
    }

    deinit { mib_cursor_close(&cursor) }

    func read(relativeOffset: Int64, count: Int) throws -> Data {
        var low = 0, high = chunks.count
        while low < high { let middle = low + (high - low) / 2; if chunks[middle].byteOffset <= relativeOffset { low = middle + 1 } else { high = middle } }
        let index = low - 1
        guard index >= 0 else { throw ProbeFailure("carrier chunk lookup") }
        let target = chunks[index]
        if cachedChunk != index {
            var error = MIBError()
            if packetAudio {
                if cursor == nil { try check(mib_cursor_open(context.originalProbe.source, stream.ordinal, 0, &cursor, &error), error) }
                if target.frame <= currentFrame { try check(mib_cursor_rewind(cursor, &error), error); currentFrame = -1 }
                var packet = MIBPacket()
                while currentFrame < target.frame {
                    try context.originalProbe.checkCancellation()
                    let status = mib_next_packet(cursor, &packet, &error); try check(status, error)
                    guard status == 1, packet.identity.ordinal_valid != 0 else { throw ProbeFailure("original audio packet replay EOF") }
                    currentFrame = packet.identity.ordinal
                }
                guard packet.bytes.size == target.byteCount, let pointer = packet.bytes.data else {
                    throw ProbeFailure("original audio packet replay size changed")
                }
                cached = Data(bytes: pointer, count: target.byteCount)
                guard ASHSHA256V4(rawData: cached) == packetHashes[index] else { throw ProbeFailure("original audio packet replay digest changed") }
            } else {
            if cursor == nil { try check(mib_cursor_open(context.originalProbe.source, stream.ordinal, stream.mediaType == 0 ? 1 : 2, &cursor, &error), error) }
            if target.frame < currentFrame { try check(mib_cursor_rewind(cursor, &error), error); currentFrame = -1 }
            var frame = MIBDecodedFrame()
            while currentFrame < target.frame {
                try context.originalProbe.checkCancellation()
                let result = mib_next_frame(cursor, &frame, &error); try check(result, error)
                guard result == 1 else { throw ProbeFailure("carrier decoder premature EOF") }
                currentFrame = frame.ordinal
            }
            // A repeated chunk is served only from cache. Re-entering a decoded
            // frame after another chunk always rewinds, so borrowed C spans are fresh.
            if stream.mediaType == 0 {
                cached = Data(count: target.byteCount)
                let result: Int32
                if let presentationPolicy {
                    let activeRow = Int(stream.width) * 4
                    var packed = Data(count: activeRow * Int(stream.height))
                    result = packed.withUnsafeMutableBytes { raw in
                        mib_presentation_bgra(&frame, presentationPolicy.sourceMatrix,
                            presentationPolicy.sourceFullRange ? 1 : 0,
                            presentationPolicy.qualifiedUnspecified8BitRange ? Int32(MIB_RANGE_QUALIFIED_UNSPECIFIED_8BIT) : Int32(MIB_RANGE_DECLARED),
                            presentationPolicy.sourceChromaLocation,
                            raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
                    }
                    if result == 0 {
                        cached.withUnsafeMutableBytes { target in
                            packed.withUnsafeBytes { source in
                                for y in 0..<Int(stream.height) {
                                    memcpy(target.baseAddress!.advanced(by: y * presentationPolicy.destinationBytesPerRow),
                                        source.baseAddress!.advanced(by: y * activeRow), activeRow)
                                }
                            }
                        }
                    }
                } else {
                result = cached.withUnsafeMutableBytes { raw in
                    if rgbConversion {
                        return mirmir_rgb8_working(&frame, 1, 1, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
                    }
                    return mib_biplanar_working(&frame, Int32(workingDepth), fullRange ? 1 : 0, interpretedUnspecifiedRange ? Int32(MIB_RANGE_QUALIFIED_UNSPECIFIED_8BIT) : Int32(MIB_RANGE_DECLARED), raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
                }
                }
                guard result == 0 else { throw ProbeFailure("carrier unsupported working pixel conversion \(result)") }
            } else {
                guard frame.audible_offset == target.audibleOffset, frame.audible_samples == target.samples,
                      frame.s32_interleaved.size >= target.byteCount + target.audibleOffset * frameBytes,
                      let pointer = frame.s32_interleaved.data else { throw ProbeFailure("carrier PCM range changed") }
                cached = Data(bytes: pointer.advanced(by: target.audibleOffset * frameBytes), count: target.byteCount)
            }
            }
            cachedChunk = index
        }
        let within = Int(relativeOffset - target.byteOffset)
        guard within >= 0, within < cached.count else { throw ProbeFailure("carrier chunk extent") }
        return cached.subdata(in: within..<min(cached.count, within + count))
    }
}

private enum CarrierMOV {
    struct Movie { let header: Data; let extent: Int64 }
    static let matrix: Data = [UInt32(65536), 0, 0, 0, 65536, 0, 0, 0, 1073741824].reduce(into: Data()) { $0.append(be($1)) }
    static func joined(_ parts: Data...) -> Data { parts.reduce(into: Data()) { $0.append($1) } }
    static func be<T: FixedWidthInteger>(_ n: T) -> Data { var n = n.bigEndian; return withUnsafeBytes(of: &n) { Data($0) } }
    static func atom(_ code: String, _ data: Data) -> Data { be(UInt32(data.count + 8)) + Data(code.utf8) + data }
    static func full(_ code: String, _ data: Data, flags: UInt32 = 0) -> Data { atom(code, be(flags) + data) }
    static func zero(_ n: Int) -> Data { Data(repeating: 0, count: n) }
    static func gcd(_ a: Int64, _ b: Int64) -> Int64 { var a = a, b = b; while b != 0 { let r = a % b; a = b; b = r }; return a }
    static func scale(_ values: [ExactRationalV4]) throws -> Int64 {
        try values.reduce(Int64(1)) { value, time in
            let (result, overflow) = (value / gcd(value, time.denominator)).multipliedReportingOverflow(by: time.denominator)
            guard !overflow, result <= Int32.max else { throw ProbeFailure("carrier exact movie timebase overflow") }; return result
        }
    }
    static func ticks(_ value: ExactRationalV4, scale: Int64) throws -> UInt64 {
        let exact = try value.multiplied(by: ExactRationalV4(scale))
        guard exact.denominator == 1, exact.numerator >= 0 else { throw ProbeFailure("carrier nonintegral timebase") }; return UInt64(exact.numerator)
    }
    static func make(tracks: [CarrierTrack]) throws -> Movie {
        let movieScale = try scale(tracks.flatMap { [$0.start, $0.duration] })
        let movieEnd = try tracks.map { try $0.start.adding($0.duration) }.max() ?? .zero
        let ftyp = atom("ftyp", Data("qt  ".utf8) + be(UInt32(0)) + Data("qt  ".utf8))
        let mvhd = full("mvhd", joined(be(UInt64(0)), be(UInt64(0)), be(UInt32(movieScale)), be(try ticks(movieEnd, scale: movieScale)), be(UInt32(65536)), be(UInt16(256)), zero(10), matrix, zero(24), be(UInt32(tracks.count + 1))), flags: 0x01000000)
        func movie() throws -> Data { atom("moov", mvhd + (try tracks.enumerated().reduce(into: Data()) { data, pair in data.append(try trak(pair.element, id: pair.offset + 1, movieScale: movieScale)) })) }
        let first = try movie()
        var offset = Int64(ftyp.count + first.count + 16)
        for track in tracks { track.payloadOffset = offset; let (next, overflow) = offset.addingReportingOverflow(track.bytes); guard !overflow else { throw ProbeFailure("carrier resource size overflow") }; offset = next }
        let header = joined(ftyp, try movie(), be(UInt32(1)), Data("mdat".utf8), be(UInt64(offset - Int64(ftyp.count + first.count))))
        guard header.count == ftyp.count + first.count + 16 else { throw ProbeFailure("carrier header offset changed") }
        return Movie(header: header, extent: offset)
    }
    static func trak(_ t: CarrierTrack, id: Int, movieScale: Int64) throws -> Data {
        let isVideo = t.stream.mediaType == 0
        let end = try t.start.adding(t.duration)
        let trackFlags: UInt32 = t.context.typedProjection.state?.tracks.first(where: { $0.identity.ordinal == UInt32(t.stream.ordinal) })?.enabled == true ? 7 : 6
        let tkhd = full("tkhd", joined(be(UInt64(0)), be(UInt64(0)), be(UInt32(id)), be(UInt32(0)), be(try ticks(end, scale: movieScale)), zero(8), be(UInt16(0)), be(UInt16(0)), be(UInt16(isVideo ? 0 : 256)), be(UInt16(0)), matrix, be(UInt32(t.stream.width) << 16), be(UInt32(t.stream.height) << 16)), flags: 0x01000000 | trackFlags)
        var edits = Data(); var editCount: UInt32 = 0
        if t.start > .zero { editCount += 1; edits += be(try ticks(t.start, scale: movieScale)) + be(Int64(-1)) + be(UInt32(65536)) }
        editCount += 1; edits += be(try ticks(t.duration, scale: movieScale)) + be(try ticks(t.mediaStart, scale: isVideo ? scale(t.durations) : Int64(t.stream.sampleRate))) + be(UInt32(65536))
        let edts = atom("edts", full("elst", be(editCount) + edits, flags: 0x01000000))
        let mediaScale = isVideo ? try scale(t.durations) : Int64(t.stream.sampleRate)
        let mdhd = full("mdhd", joined(be(UInt64(0)), be(UInt64(0)), be(UInt32(mediaScale)), be(try ticks(t.mediaDuration, scale: mediaScale)), be(UInt16(0)), be(UInt16(0))), flags: 0x01000000)
        let hdlr = full("hdlr", Data((isVideo ? "mhlrvide" : "mhlrsoun").utf8) + Data("appl".utf8) + zero(8) + Data([isVideo ? 11 : 13]) + Data((isVideo ? "Video Media" : "Sound Handler").utf8))
        let minHeader = isVideo ? full("vmhd", be(UInt16(64)) + zero(6), flags: 1) : full("smhd", zero(4))
        let dinf = atom("dinf", full("dref", be(UInt32(1)) + full("url ", Data(), flags: 1)))
        let entry = isVideo ? try videoEntry(t) : audioEntry(t)
        let stsd = full("stsd", be(UInt32(1)) + entry)
        var ts: [(UInt32, UInt32)] = []
        if isVideo || t.compressedAudio {
            for duration in t.durations {
                let ticks = try ticks(duration, scale: mediaScale)
                guard ticks <= UInt32.max else { throw ProbeFailure("carrier frame delta overflow") }
                if ts.last?.1 == UInt32(ticks) { ts[ts.count - 1].0 += 1 } else { ts.append((1, UInt32(ticks))) }
            }
        } else {
            let count = t.chunks.reduce(Int64(0)) { $0 + Int64($1.samples) }
            guard count <= UInt32.max else { throw ProbeFailure("private carrier PCM sample-table bound") }; ts = [(UInt32(count), 1)]
        }
        let stts = full("stts", be(UInt32(ts.count)) + ts.reduce(into: Data()) { $0 += be($1.0) + be($1.1) })
        var sc: [(UInt32, UInt32)] = []
        for (i, chunk) in t.chunks.enumerated() where sc.last?.1 != UInt32(chunk.samples) { sc.append((UInt32(i + 1), UInt32(chunk.samples))) }
        let stsc = full("stsc", be(UInt32(sc.count)) + sc.reduce(into: Data()) { $0 += be($1.0) + be($1.1) + be(UInt32(1)) })
        let samples = isVideo || t.compressedAudio ? Int64(t.chunks.count) : t.chunks.reduce(Int64(0)) { $0 + Int64($1.samples) }
        guard samples <= UInt32.max else { throw ProbeFailure("private carrier sample count bound") }
        let stsz = full("stsz", be(UInt32(t.frameBytes)) + be(UInt32(samples))
            + (t.compressedAudio ? t.chunks.reduce(into: Data()) { $0 += be(UInt32($1.byteCount)) } : Data()))
        let co64 = full("co64", be(UInt32(t.chunks.count)) + t.chunks.reduce(into: Data()) { $0 += be(UInt64(t.payloadOffset + $1.byteOffset)) })
        let audioRoll = t.compressedAudio
            ? full("sgpd", Data("roll".utf8) + be(UInt32(2)) + be(UInt32(1)) + be(Int16(-1)), flags: 0x01000000)
                + full("sbgp", Data("roll".utf8) + be(UInt32(1)) + be(UInt32(samples)) + be(UInt32(1)))
            : Data()
        return atom("trak", tkhd + edts + atom("mdia", mdhd + hdlr + atom("minf", minHeader + dinf + atom("stbl", stsd + stts + stsc + stsz + co64 + audioRoll))))
    }
    static func videoEntry(_ t: CarrierTrack) throws -> Data {
        let presentation = t.presentationPolicy != nil
        guard let color = t.color else { throw ProbeFailure("carrier video color missing") }
        let codec = presentation ? "BGRA" : (t.workingFormat ?? "INVALID")
        guard codec.utf8.count == 4 else { throw ProbeFailure("carrier video subtype missing") }
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: color.primaries as CFString,
            kCMFormatDescriptionExtension_TransferFunction: color.transferFunction as CFString,
            kCMFormatDescriptionExtension_FieldCount: 1,
            kCMFormatDescriptionExtension_FullRangeVideo: presentation || t.fullRange,
            kCMFormatDescriptionExtension_PixelAspectRatio: [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: 1,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: 1],
            kCMFormatDescriptionExtension_CleanAperture: [
                kCMFormatDescriptionKey_CleanApertureWidth: t.stream.width,
                kCMFormatDescriptionKey_CleanApertureHeight: t.stream.height,
                kCMFormatDescriptionKey_CleanApertureHorizontalOffset: 0,
                kCMFormatDescriptionKey_CleanApertureVerticalOffset: 0]
        ]
        if presentation {
            extensions[kCMFormatDescriptionExtension_BytesPerRow] = t.presentationPolicy!.destinationBytesPerRow
        } else {
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = color.matrix as CFString
            guard let policy = t.context.workingDecodePolicy?.tracks.first(where: {
                $0.sourceOrdinal == t.stream.ordinal
            }) else { throw ProbeFailure("carrier working phase missing") }
            let location: CFString
            switch policy.destinationSiting {
            case .left: location = kCVImageBufferChromaLocation_Left
            case .center: location = kCVImageBufferChromaLocation_Center
            case .topLeft: location = kCVImageBufferChromaLocation_TopLeft
            case .top: location = kCVImageBufferChromaLocation_Top
            case .bottomLeft: location = kCVImageBufferChromaLocation_BottomLeft
            case .bottom: location = kCVImageBufferChromaLocation_Bottom
            case .unknown, .notApplicable: throw ProbeFailure("unqualified carrier working phase")
            }
            extensions[kCMFormatDescriptionExtension_ChromaLocationTopField] = location
            extensions[kCMFormatDescriptionExtension_ChromaLocationBottomField] = location
        }
        var format: CMVideoFormatDescription?
        let created = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: codec.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) },
            width: t.stream.width, height: t.stream.height, extensions: extensions as CFDictionary,
            formatDescriptionOut: &format)
        guard created == noErr, let format else { throw ProbeFailure("native carrier video format failed") }
        var block: CMBlockBuffer?
        let copied = CMVideoFormatDescriptionCopyAsBigEndianImageDescriptionBlockBuffer(
            allocator: kCFAllocatorDefault, videoFormatDescription: format,
            stringEncoding: CFStringGetSystemEncoding(), flavor: nil, blockBufferOut: &block)
        guard copied == noErr, let block else { throw ProbeFailure("native carrier sample description failed") }
        var entry = Data(count: CMBlockBufferGetDataLength(block))
        let read = entry.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard read == noErr, entry.count >= 86, entry.count <= 65_536 else {
            throw ProbeFailure("native carrier sample-description extent invalid")
        }
        // The documented bridge deliberately emits0xFFFF; this movie owns dref1.
        entry[14] = 0; entry[15] = 1
        return entry
    }
    static func audioEntry(_ t: CarrierTrack) -> Data {
        let channels = UInt32(t.stream.channels)
        if t.compressedAudio {
            func descriptor(_ tag: UInt8, _ payload: Data) -> Data {
                let n = payload.count
                return Data([tag, UInt8((n >> 21) & 127) | 128,
                    UInt8((n >> 14) & 127) | 128, UInt8((n >> 7) & 127) | 128,
                    UInt8(n & 127)]) + payload
            }
            let config = descriptor(5, t.stream.extradata)
            let decoder = descriptor(4, Data([0x40, 0x15]) + zero(3) + be(UInt32(0)) + be(UInt32(0)) + config)
            let esds = full("esds", descriptor(3, be(UInt16(2)) + Data([0]) + decoder + descriptor(6, Data([2]))))
            let wave = atom("wave", atom("frma", Data("mp4a".utf8))
                + atom("mp4a", be(UInt32(0))) + esds + be(UInt32(8)) + be(UInt32(0)))
            let entry = joined(zero(6), be(UInt16(1)), be(UInt16(1)), zero(6),
                be(UInt16(channels)), be(UInt16(16)), be(Int16(-2)), be(UInt16(0)),
                be(UInt32(t.stream.sampleRate) << 16), be(UInt32(1024)),
                be(UInt32(0)), be(UInt32(0)), be(UInt32(2)), wave)
            return atom("mp4a", entry)
        }
        let bits: UInt32 = t.packetAudio ? 16 : 32
        let rateBits = Double(t.stream.sampleRate).bitPattern
        let e = joined(zero(6), be(UInt16(1)), be(UInt16(2)), be(UInt16(0)), be(UInt32(0)), be(UInt16(3)), be(UInt16(16)), be(UInt16(65534)), be(UInt16(0)), be(UInt32(65536)), be(UInt32(72)), be(rateBits), be(channels), be(UInt32(0x7f000000)), be(bits), be(UInt32(12)), be(channels * (bits / 8)), be(UInt32(1)))
        return atom("lpcm", e)
    }
}
