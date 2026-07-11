import CoreVideo
import Foundation

private struct ASHNV12CodeFrameV2 {
    let luma: ASHVideoAnalyzerV2CodePlane
    let cb: ASHVideoAnalyzerV2CodePlane
    let cr: ASHVideoAnalyzerV2CodePlane
    let chromaSiting: ASHChromaSitingV2
}

@available(macOS 15.4, *)
final class ASHDeterministicUpscaleBackend: @unchecked Sendable {
    private let route: ASHSpatialRouteV2
    private let runtimeConfiguration: ASHSpatialRuntimeConfigurationV2
    private let operatorParameters: ASHSpatialDevelopmentParametersV2
    private let stateInputEnabled: Bool
    private let telemetry: any ASHTelemetryRecording
    private(set) var lastDebugSummary: ASHSpatialReferenceSummaryV2?

    init(
        route: ASHSpatialRouteV2,
        runtimeConfiguration: ASHSpatialRuntimeConfigurationV2 = .developmentP05,
        operatorParameters: ASHSpatialDevelopmentParametersV2 = .p05DevelopmentOnly,
        stateInputEnabled: Bool = true,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) {
        self.route = route
        self.runtimeConfiguration = runtimeConfiguration
        self.operatorParameters = operatorParameters
        self.stateInputEnabled = stateInputEnabled
        self.telemetry = telemetry
    }

    func reset() {
        lastDebugSummary = nil
    }

    func process(source: CVPixelBuffer, into destination: CVPixelBuffer) async throws {
        try Task.checkCancellation()
        let sourceFrame = try telemetry.measure(.canonicalize) {
            try Self.extractNV12(from: source)
        }
        telemetry.increment(.fullFrameCopies, by: 3)
        telemetry.increment(.fullFrameCPULoops, by: 2)

        let output = try ASHSpatialReferencePipelineV2.process(
            ASHSpatialReferenceInputV2(
                luma: sourceFrame.luma,
                cb: sourceFrame.cb,
                cr: sourceFrame.cr,
                chromaSiting: sourceFrame.chromaSiting,
                route: route,
                runtimeConfiguration: runtimeConfiguration,
                analyzerConfiguration: try .makeDisposableP05Reference(),
                operatorParameters: operatorParameters,
                stateInputEnabled: stateInputEnabled
            ),
            telemetry: telemetry
        )
        try Task.checkCancellation()
        try Self.write(output, chromaSiting: sourceFrame.chromaSiting, to: destination)
        telemetry.increment(.fullFrameCopies, by: 3)
        telemetry.increment(.fullFrameCPULoops, by: 2)
        lastDebugSummary = output.summary
    }

    private static func extractNV12(from pixelBuffer: CVPixelBuffer) throws -> ASHNV12CodeFrameV2 {
        let range = try codeRange(for: pixelBuffer)
        let chromaSiting = try chromaSiting(for: pixelBuffer)
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw UpscalerEngineError.strategyFailed("ASH v2 requires a two-plane NV12 source")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        guard lumaStride >= lumaWidth,
              chromaStride >= chromaWidth * 2,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw UpscalerEngineError.strategyFailed("ASH v2 could not access the source NV12 planes")
        }

        let lumaPointer = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chromaPointer = chromaBase.assumingMemoryBound(to: UInt8.self)
        var lumaCodes: [UInt8] = []
        var cbCodes: [UInt8] = []
        var crCodes: [UInt8] = []
        lumaCodes.reserveCapacity(lumaWidth * lumaHeight)
        cbCodes.reserveCapacity(chromaWidth * chromaHeight)
        crCodes.reserveCapacity(chromaWidth * chromaHeight)

        for row in 0..<lumaHeight {
            let rowBase = lumaPointer.advanced(by: row * lumaStride)
            for column in 0..<lumaWidth {
                lumaCodes.append(rowBase[column])
            }
        }
        for row in 0..<chromaHeight {
            let rowBase = chromaPointer.advanced(by: row * chromaStride)
            for column in 0..<chromaWidth {
                cbCodes.append(rowBase[column * 2])
                crCodes.append(rowBase[column * 2 + 1])
            }
        }

        return ASHNV12CodeFrameV2(
            luma: try ASHVideoAnalyzerV2CodePlane(
                width: lumaWidth,
                height: lumaHeight,
                bytesPerRow: lumaWidth,
                codes: lumaCodes,
                range: range
            ),
            cb: try ASHVideoAnalyzerV2CodePlane(
                width: chromaWidth,
                height: chromaHeight,
                bytesPerRow: chromaWidth,
                codes: cbCodes,
                range: range
            ),
            cr: try ASHVideoAnalyzerV2CodePlane(
                width: chromaWidth,
                height: chromaHeight,
                bytesPerRow: chromaWidth,
                codes: crCodes,
                range: range
            ),
            chromaSiting: chromaSiting
        )
    }

    private static func write(
        _ output: ASHSpatialReferenceOutputV2,
        chromaSiting: ASHChromaSitingV2,
        to destination: CVPixelBuffer
    ) throws {
        let range = try codeRange(for: destination)
        guard CVPixelBufferGetPlaneCount(destination) == 2 else {
            throw UpscalerEngineError.strategyFailed("ASH v2 requires a two-plane NV12 destination")
        }
        setChromaSiting(chromaSiting, on: destination)

        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        try writeLuma(output.luma, range: range, to: destination)
        try writeChroma(cb: output.cb, cr: output.cr, range: range, to: destination)
    }

    private static func writeLuma(
        _ output: ASHSpatialReferencePlaneOutputV2,
        range: ASHVideoCodeRange8Bit,
        to destination: CVPixelBuffer
    ) throws {
        let width = CVPixelBufferGetWidthOfPlane(destination, 0)
        let height = CVPixelBufferGetHeightOfPlane(destination, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(destination, 0)
        guard width == output.width,
              height == output.height,
              output.normalizedSamples.count == width * height,
              let base = CVPixelBufferGetBaseAddressOfPlane(destination, 0) else {
            throw UpscalerEngineError.strategyFailed("ASH v2 luma output dimensions do not match the destination")
        }
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let rowBase = pointer.advanced(by: row * stride)
            for column in 0..<width {
                rowBase[column] = range.encodeLuma(output.normalizedSamples[(row * width) + column])
            }
        }
    }

    private static func writeChroma(
        cb: ASHSpatialReferencePlaneOutputV2,
        cr: ASHSpatialReferencePlaneOutputV2,
        range: ASHVideoCodeRange8Bit,
        to destination: CVPixelBuffer
    ) throws {
        let width = CVPixelBufferGetWidthOfPlane(destination, 1)
        let height = CVPixelBufferGetHeightOfPlane(destination, 1)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(destination, 1)
        guard width == cb.width,
              height == cb.height,
              cr.width == width,
              cr.height == height,
              cb.normalizedSamples.count == width * height,
              cr.normalizedSamples.count == width * height,
              let base = CVPixelBufferGetBaseAddressOfPlane(destination, 1) else {
            throw UpscalerEngineError.strategyFailed("ASH v2 chroma output dimensions do not match the destination")
        }
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let rowBase = pointer.advanced(by: row * stride)
            for column in 0..<width {
                let sampleIndex = (row * width) + column
                rowBase[column * 2] = range.encodeChroma(cb.normalizedSamples[sampleIndex])
                rowBase[column * 2 + 1] = range.encodeChroma(cr.normalizedSamples[sampleIndex])
            }
        }
    }

    private static func codeRange(for pixelBuffer: CVPixelBuffer) throws -> ASHVideoCodeRange8Bit {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return .video
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return .full
        default:
            throw UpscalerEngineError.strategyFailed("ASH v2 supports only 420v and 420f pixel buffers")
        }
    }

    private static func chromaSiting(for pixelBuffer: CVPixelBuffer) throws -> ASHChromaSitingV2 {
        guard let attachment = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferChromaLocationTopFieldKey,
            nil
        ) as? String else {
            throw UpscalerEngineError.strategyFailed("ASH v2 requires an explicit progressive chroma location")
        }
        if attachment == kCVImageBufferChromaLocation_Center as String {
            return .center
        }
        if attachment == kCVImageBufferChromaLocation_Left as String {
            return .left
        }
        if attachment == kCVImageBufferChromaLocation_TopLeft as String {
            return .topLeft
        }
        if attachment == kCVImageBufferChromaLocation_Top as String {
            return .top
        }
        if attachment == kCVImageBufferChromaLocation_BottomLeft as String {
            return .bottomLeft
        }
        if attachment == kCVImageBufferChromaLocation_Bottom as String {
            return .bottom
        }
        throw UpscalerEngineError.strategyFailed("ASH v2 does not support chroma location \(attachment)")
    }

    private static func setChromaSiting(_ siting: ASHChromaSitingV2, on pixelBuffer: CVPixelBuffer) {
        let value: CFString
        switch siting {
        case .center:
            value = kCVImageBufferChromaLocation_Center
        case .left:
            value = kCVImageBufferChromaLocation_Left
        case .topLeft:
            value = kCVImageBufferChromaLocation_TopLeft
        case .top:
            value = kCVImageBufferChromaLocation_Top
        case .bottomLeft:
            value = kCVImageBufferChromaLocation_BottomLeft
        case .bottom:
            value = kCVImageBufferChromaLocation_Bottom
        }
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferChromaLocationTopFieldKey,
            value,
            .shouldPropagate
        )
    }
}

private extension ASHVideoCodeRange8Bit {
    func encodeLuma(_ normalized: Double) -> UInt8 {
        switch self {
        case .video:
            return encode(normalized, minimum: 16.0, maximum: 235.0)
        case .full:
            return encode(normalized, minimum: 0.0, maximum: 255.0)
        }
    }

    func encodeChroma(_ normalized: Double) -> UInt8 {
        switch self {
        case .video:
            return encode(normalized, minimum: 16.0, maximum: 240.0)
        case .full:
            return encode(normalized, minimum: 0.0, maximum: 255.0)
        }
    }

    func encode(_ normalized: Double, minimum: Double, maximum: Double) -> UInt8 {
        let unit = min(1.0, max(0.0, normalized))
        return UInt8((minimum + (unit * (maximum - minimum))).rounded())
    }
}
