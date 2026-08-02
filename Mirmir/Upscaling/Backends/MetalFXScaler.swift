import CoreVideo
import Foundation
@preconcurrency import Metal
@preconcurrency import MetalFX

struct MetalFXBackend: UpscaleBackend {
    let descriptor: BackendDescriptor

    init?(descriptor: BackendDescriptor) {
        guard descriptor.id == .metalFXSpatial else { return nil }
        self.descriptor = descriptor
    }

    func availability(for source: VideoInfo, targetSize: CGSize, environment: RuntimeEnvironment) async -> BackendAvailability {
        switch metalFXConfiguration(source: source, targetSize: targetSize) {
        case .unavailable(let reason): return .unavailable(reason: reason)
        case .valid:
            return await environment.capabilityProbe.availability(for: descriptor.id, source: source, targetSize: targetSize)
        }
    }

    func prepare(request: BackendPreparationRequest, environment: RuntimeEnvironment) async throws -> any PreparedFrameUpscaler {
        let configuration: NV12ScalerConfiguration
        switch metalFXConfiguration(source: request.source, targetSize: request.targetSize) {
        case .valid(let value): configuration = value
        case .unavailable(let reason): throw BackendPreparationError.unavailable(descriptor.id, reason)
        }
        let availability = await environment.capabilityProbe.availability(for: descriptor.id, source: request.source, targetSize: request.targetSize)
        guard availability == .available else {
            if case .unavailable(let reason) = availability { throw BackendPreparationError.unavailable(descriptor.id, reason) }
            throw BackendPreparationError.unavailable(descriptor.id, .modelUnavailable(details: "MetalFX Spatial does not use a downloadable model"))
        }
        return try PreparedMetalFXScaler(configuration: configuration)
    }

    private func metalFXConfiguration(source: VideoInfo, targetSize: CGSize) -> NV12ScalerConfigurationValidation {
        switch NV12ScalerConfiguration.validate(source: source, targetSize: targetSize, backendID: descriptor.id) {
        case .unavailable(let reason): return .unavailable(reason)
        case .valid(let configuration):
            guard configuration.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
                return .unavailable(.unsupportedPixelFormatOrBitDepth(
                    details: "The audited MetalFX color bridge accepts 8-bit video-range NV12 (420v); full-range conversion is not inferred"
                ))
            }
            let expected = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
            guard source.color.colorPrimaries == expected,
                  source.color.transferFunction == (kCVImageBufferTransferFunction_ITU_R_709_2 as String),
                  source.color.yCbCrMatrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) else {
                return .unavailable(.unsupportedPixelFormatOrBitDepth(
                    details: "The audited MetalFX bridge requires explicitly tagged BT.709 primaries, transfer function, and YCbCr matrix"
                ))
            }
            return .valid(configuration)
        }
    }
}

actor PreparedMetalFXScaler: PreparedFrameUpscaler {
    nonisolated let sourcePixelBufferAttributes: PixelBufferAttributes
    nonisolated let destinationPixelBufferAttributes: PixelBufferAttributes
    nonisolated let actualBackendID: UpscaleBackendID

    private let configuration: NV12ScalerConfiguration
    private let queue: any MTLCommandQueue
    private let scaler: any MTLFXSpatialScaler
    private let inputTexture: any MTLTexture
    private let outputTexture: any MTLTexture
    private let inputStagingTexture: any MTLTexture
    private let outputStagingTexture: any MTLTexture
    private let bytesPerRow: Int
    private var finished = false

    init(configuration: NV12ScalerConfiguration) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              MTLFXSpatialScalerDescriptor.supportsDevice(device),
              let queue = device.makeCommandQueue() else {
            throw configuration.processingError("MetalFX Spatial could not create a supported device or command queue")
        }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.colorTextureFormat = .rgba16Float
        descriptor.outputTextureFormat = .rgba16Float
        descriptor.inputWidth = configuration.sourceWidth
        descriptor.inputHeight = configuration.sourceHeight
        descriptor.outputWidth = configuration.targetWidth
        descriptor.outputHeight = configuration.targetHeight
        descriptor.colorProcessingMode = .linear
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            throw configuration.processingError("MetalFX rejected the requested RGBA16Float spatial configuration")
        }

        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: configuration.sourceWidth,
            height: configuration.sourceHeight,
            mipmapped: false
        )
        inputDescriptor.storageMode = .private
        inputDescriptor.usage = scaler.colorTextureUsage.union(.shaderRead)
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: configuration.targetWidth,
            height: configuration.targetHeight,
            mipmapped: false
        )
        outputDescriptor.storageMode = .private
        outputDescriptor.usage = scaler.outputTextureUsage.union([.shaderRead, .shaderWrite])
        let inputStagingDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: configuration.sourceWidth,
            height: configuration.sourceHeight,
            mipmapped: false
        )
        inputStagingDescriptor.storageMode = .shared
        inputStagingDescriptor.cpuCacheMode = .writeCombined
        let outputStagingDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: configuration.targetWidth,
            height: configuration.targetHeight,
            mipmapped: false
        )
        outputStagingDescriptor.storageMode = .shared
        guard let inputTexture = device.makeTexture(descriptor: inputDescriptor),
              let outputTexture = device.makeTexture(descriptor: outputDescriptor),
              let inputStagingTexture = device.makeTexture(descriptor: inputStagingDescriptor),
              let outputStagingTexture = device.makeTexture(descriptor: outputStagingDescriptor) else {
            throw configuration.processingError("Metal could not allocate the explicit linear-RGB bridge textures")
        }
        let row = configuration.targetWidth.multipliedReportingOverflow(by: 8)
        guard !row.overflow else {
            throw configuration.processingError("RGBA16Float row-byte calculation overflowed")
        }
        self.configuration = configuration
        self.queue = queue
        self.scaler = scaler
        self.inputTexture = inputTexture
        self.outputTexture = outputTexture
        self.inputStagingTexture = inputStagingTexture
        self.outputStagingTexture = outputStagingTexture
        bytesPerRow = row.partialValue
        actualBackendID = configuration.backendID
        sourcePixelBufferAttributes = configuration.attributes(width: configuration.sourceWidth, height: configuration.sourceHeight)
        destinationPixelBufferAttributes = configuration.attributes(width: configuration.targetWidth, height: configuration.targetHeight)
    }

    func process(source: FramePixelBuffer, destination: FramePixelBuffer, timing: FrameTiming) async throws {
        let source = source.value
        let destination = destination.value
        guard !finished else { throw configuration.processingError("the prepared adapter is already finished", frameIndex: timing.frameIndex) }
        try Task.checkCancellation()
        try configuration.validate(source, source: true)
        try configuration.validate(destination, source: false)
        let linearInput = try MetalFXBT709Bridge.decode(source, configuration: configuration)
        let inputBytesPerRow = configuration.sourceWidth * 8
        linearInput.withUnsafeBytes { bytes in
            inputStagingTexture.replace(
                region: MTLRegionMake2D(0, 0, configuration.sourceWidth, configuration.sourceHeight),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: inputBytesPerRow
            )
        }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let upload = commandBuffer.makeBlitCommandEncoder() else {
            throw configuration.processingError("Metal could not create the upload command encoder", frameIndex: timing.frameIndex)
        }
        upload.copy(
            from: inputStagingTexture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: configuration.sourceWidth, height: configuration.sourceHeight, depth: 1),
            to: inputTexture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        upload.endEncoding()
        scaler.inputContentWidth = configuration.sourceWidth
        scaler.inputContentHeight = configuration.sourceHeight
        scaler.colorTexture = inputTexture
        scaler.outputTexture = outputTexture
        scaler.encode(commandBuffer: commandBuffer)
        guard let download = commandBuffer.makeBlitCommandEncoder() else {
            throw configuration.processingError("Metal could not create the readback command encoder", frameIndex: timing.frameIndex)
        }
        download.copy(
            from: outputTexture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: configuration.targetWidth, height: configuration.targetHeight, depth: 1),
            to: outputStagingTexture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        download.endEncoding()
        try Task.checkCancellation()
        commandBuffer.commit()
        await commandBuffer.completed()
        guard commandBuffer.status == .completed else {
            throw configuration.processingError(commandBuffer.error?.localizedDescription ?? "the MetalFX command failed", frameIndex: timing.frameIndex)
        }

        let componentCount = configuration.targetWidth * configuration.targetHeight * 4
        var linearOutput = [UInt16](repeating: 0, count: componentCount)
        linearOutput.withUnsafeMutableBytes { bytes in
            outputStagingTexture.getBytes(
                bytes.baseAddress!, bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, configuration.targetWidth, configuration.targetHeight),
                mipmapLevel: 0
            )
        }
        try MetalFXBT709Bridge.encode(linearOutput, into: destination, configuration: configuration)
        try Task.checkCancellation()
    }

    func finish() async throws { finished = true }
}

private enum MetalFXBT709Bridge {
    private static let kr = 0.2126
    private static let kb = 0.0722
    private static let kg = 1 - kr - kb

    static func decode(_ source: CVPixelBuffer, configuration: NV12ScalerConfiguration) throws -> [UInt16] {
        try validateAttachments(source, configuration: configuration)
        let status = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard status == kCVReturnSuccess else { throw configuration.processingError("NV12 source lock failed (\(status))") }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(source, 0)?.assumingMemoryBound(to: UInt8.self),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(source, 1)?.assumingMemoryBound(to: UInt8.self) else {
            throw configuration.processingError("NV12 source planes are not CPU-accessible")
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
        var output = [UInt16](repeating: 0, count: configuration.sourceWidth * configuration.sourceHeight * 4)
        for row in 0..<configuration.sourceHeight {
            for column in 0..<configuration.sourceWidth {
                let y = clamp((Double(yBase[row * yStride + column]) - 16) / 219)
                let chroma = interpolatedChroma(
                    base: cBase, stride: cStride,
                    width: configuration.sourceWidth / 2,
                    height: configuration.sourceHeight / 2,
                    column: column, row: row
                )
                let encodedR = clamp(y + 2 * (1 - kr) * chroma.cr)
                let encodedB = clamp(y + 2 * (1 - kb) * chroma.cb)
                let encodedG = clamp(y - (2 * kb * (1 - kb) / kg) * chroma.cb - (2 * kr * (1 - kr) / kg) * chroma.cr)
                let index = (row * configuration.sourceWidth + column) * 4
                output[index] = IEEE754Half.encode(eotf(encodedR))
                output[index + 1] = IEEE754Half.encode(eotf(encodedG))
                output[index + 2] = IEEE754Half.encode(eotf(encodedB))
                output[index + 3] = IEEE754Half.encode(1)
            }
        }
        return output
    }

    static func encode(_ source: [UInt16], into destination: CVPixelBuffer, configuration: NV12ScalerConfiguration) throws {
        let width = configuration.targetWidth
        let height = configuration.targetHeight
        guard source.count == width * height * 4 else { throw configuration.processingError("MetalFX readback has an invalid component count") }
        for (index, component) in source.enumerated() {
            guard IEEE754Half.decode(component).isFinite else {
                throw configuration.processingError("MetalFX readback contains a non-finite component at index \(index)")
            }
        }
        let status = CVPixelBufferLockBaseAddress(destination, [])
        guard status == kCVReturnSuccess else { throw configuration.processingError("NV12 destination lock failed (\(status))") }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(destination, 0)?.assumingMemoryBound(to: UInt8.self),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(destination, 1)?.assumingMemoryBound(to: UInt8.self) else {
            throw configuration.processingError("NV12 destination planes are not CPU-accessible")
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 1)
        for row in 0..<height {
            for column in 0..<width {
                let rgb = encodedRGB(source, width: width, column: column, row: row)
                let luma = kr * rgb.r + kg * rgb.g + kb * rgb.b
                yBase[row * yStride + column] = UInt8((16 + 219 * clamp(luma)).rounded())
            }
        }
        for chromaRow in 0..<(height / 2) {
            for chromaColumn in 0..<(width / 2) {
                let column = chromaColumn * 2
                let row = chromaRow * 2
                let top = chroma(source, width: width, column: column, row: row)
                let bottom = chroma(source, width: width, column: column, row: row + 1)
                let offset = chromaRow * cStride + chromaColumn * 2
                cBase[offset] = quantizedChroma((top.cb + bottom.cb) / 2)
                cBase[offset + 1] = quantizedChroma((top.cr + bottom.cr) / 2)
            }
        }
        installAttachments(destination)
    }

    private static func validateAttachments(_ buffer: CVPixelBuffer, configuration: NV12ScalerConfiguration) throws {
        let expected: [(CFString, CFString)] = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        ]
        for (key, value) in expected {
            guard (CVBufferCopyAttachment(buffer, key, nil) as? String) == value as String else {
                throw configuration.processingError("decoded frame attachment \(key) does not match the explicit BT.709 bridge contract")
            }
        }
    }

    private static func installAttachments(_ buffer: CVPixelBuffer) {
        let values: [(CFString, CFString)] = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left)
        ]
        for (key, value) in values { CVBufferSetAttachment(buffer, key, value, .shouldPropagate) }
    }

    private static func interpolatedChroma(base: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int, column: Int, row: Int) -> (cb: Double, cr: Double) {
        let sampleX = Double(column) / 2
        let sampleY = (Double(row) - 0.5) / 2
        let x0 = min(width - 1, max(0, Int(floor(sampleX))))
        let x1 = min(width - 1, x0 + 1)
        let y0 = min(height - 1, max(0, Int(floor(sampleY))))
        let y1 = min(height - 1, y0 + 1)
        let wx = sampleX <= 0 ? 0 : min(1, sampleX - floor(sampleX))
        let wy = sampleY <= 0 ? 0 : min(1, sampleY - floor(sampleY))
        func value(_ x: Int, _ y: Int) -> (Double, Double) {
            let index = y * stride + x * 2
            return ((Double(base[index]) - 128) / 224, (Double(base[index + 1]) - 128) / 224)
        }
        func mix(_ a: (Double, Double), _ b: (Double, Double), _ weight: Double) -> (Double, Double) {
            (a.0 + (b.0 - a.0) * weight, a.1 + (b.1 - a.1) * weight)
        }
        let top = mix(value(x0, y0), value(x1, y0), wx)
        let bottom = mix(value(x0, y1), value(x1, y1), wx)
        let result = mix(top, bottom, wy)
        return (result.0, result.1)
    }

    private static func encodedRGB(_ source: [UInt16], width: Int, column: Int, row: Int) -> (r: Double, g: Double, b: Double) {
        let index = (row * width + column) * 4
        return (
            oetf(IEEE754Half.decode(source[index])),
            oetf(IEEE754Half.decode(source[index + 1])),
            oetf(IEEE754Half.decode(source[index + 2]))
        )
    }

    private static func chroma(_ source: [UInt16], width: Int, column: Int, row: Int) -> (cb: Double, cr: Double) {
        let rgb = encodedRGB(source, width: width, column: column, row: row)
        let luma = kr * rgb.r + kg * rgb.g + kb * rgb.b
        return ((rgb.b - luma) / (2 * (1 - kb)), (rgb.r - luma) / (2 * (1 - kr)))
    }

    private static func quantizedChroma(_ value: Double) -> UInt8 {
        UInt8((128 + 224 * min(0.5, max(-0.5, value))).rounded())
    }

    private static func eotf(_ encoded: Double) -> Double {
        let value = clamp(encoded)
        return value < 0.081 ? value / 4.5 : pow((value + 0.099) / 1.099, 1 / 0.45)
    }

    private static func oetf(_ linear: Double) -> Double {
        let value = clamp(linear)
        return value < 0.018 ? 4.5 * value : 1.099 * pow(value, 0.45) - 0.099
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}

/// Metal textures store RGBA16Float components as IEEE 754 binary16 bit patterns.
/// Swift's `Float16` is unavailable for the x86_64 macOS deployment slice, so the
/// bridge converts those bit patterns explicitly and remains architecture-neutral.
private enum IEEE754Half {
    static func encode(_ value: Double) -> UInt16 {
        let bits = Float(value).bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let sourceExponent = Int((bits >> 23) & 0xff)
        let mantissa = bits & 0x007f_ffff

        if sourceExponent == 0xff {
            guard mantissa != 0 else { return sign | 0x7c00 }
            let payload = UInt16(mantissa >> 13)
            return sign | 0x7c00 | (payload == 0 ? 1 : payload)
        }

        let exponent = sourceExponent - 127 + 15
        if exponent >= 31 { return sign | 0x7c00 }
        if exponent <= 0 {
            if exponent < -10 { return sign }
            let significand = mantissa | 0x0080_0000
            let shift = 14 - exponent
            var halfMantissa = significand >> shift
            let remainder = significand & ((UInt32(1) << shift) - 1)
            let halfway = UInt32(1) << (shift - 1)
            if remainder > halfway || (remainder == halfway && (halfMantissa & 1) == 1) {
                halfMantissa += 1
            }
            return sign | UInt16(halfMantissa)
        }

        var half = UInt32(exponent << 10) | (mantissa >> 13)
        let remainder = mantissa & 0x1fff
        if remainder > 0x1000 || (remainder == 0x1000 && (half & 1) == 1) {
            half += 1
        }
        return sign | UInt16(half)
    }

    static func decode(_ value: UInt16) -> Double {
        let sign = UInt32(value & 0x8000) << 16
        let exponent = UInt32((value >> 10) & 0x1f)
        var mantissa = UInt32(value & 0x03ff)
        let bits: UInt32

        switch exponent {
        case 0 where mantissa == 0:
            bits = sign
        case 0:
            var unbiasedExponent = -14
            while (mantissa & 0x0400) == 0 {
                mantissa <<= 1
                unbiasedExponent -= 1
            }
            mantissa &= 0x03ff
            bits = sign | UInt32(unbiasedExponent + 127) << 23 | mantissa << 13
        case 0x1f:
            bits = sign | 0x7f80_0000 | mantissa << 13
        default:
            bits = sign | (exponent + 112) << 23 | mantissa << 13
        }
        return Double(Float(bitPattern: bits))
    }
}
