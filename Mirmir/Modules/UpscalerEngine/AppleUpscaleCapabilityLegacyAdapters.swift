import Accelerate
import CoreImage
import CoreImage.CIFilterBuiltins
import Dispatch
import Foundation
import Metal
import MetalPerformanceShaders

// swiftlint:disable file_length

// The R01 matrix intentionally groups multiple framework methods into A13, A14,
// and A16. A runnable resolution below means one unit executes every grouped
// method against every fixture frozen for that capability. It is capability
// evidence only; none of these adapters confer product or quality qualification.
enum R01LegacyRuntimeAdapterResolution {
    case runnable(() throws -> any R01CapabilityRuntimeSession)
    case incompatible(reason: R01ReasonCode, limitation: String)
}

enum R01LegacyCapabilityRuntimeFactory {
    static let capabilityIDs: Set<R01CapabilityID> = [
        .a11, .a12, .a13, .a14, .a15, .a16, .a17
    ]

    static func resolve(
        id: R01CapabilityID,
        context: R01LiveProbeContext
    ) -> R01LegacyRuntimeAdapterResolution? {
        switch id {
        case .a11:
            return .runnable {
                try R01MPSScaleRuntimeSession(context: context, method: .lanczos)
            }
        case .a12:
            return .runnable {
                try R01MPSScaleRuntimeSession(context: context, method: .bilinear)
            }
        case .a13:
            return .runnable { try R01MPSGroupedSupportRuntimeSession(context: context) }
        case .a14:
            return .runnable { try R01CoreImageScaleRuntimeSession(context: context) }
        case .a15:
            return .incompatible(
                reason: .inputContractUnsatisfied,
                limitation: "CIEdgePreserveUpsample requires a smaller smallImage; "
                    + "the frozen support-frame and support-guidance inputs are both "
                    + "1920x1080."
            )
        case .a16:
            return .runnable { try R01VImageScaleRuntimeSession(context: context) }
        case .a17:
            return .runnable { try R01MetalSupportRuntimeSession(context: context) }
        default:
            return nil
        }
    }
}

private enum R01LegacyDeadline {
    static func check(_ deadline: ContinuousClock.Instant) throws {
        guard ContinuousClock().now < deadline else { throw R01ExecutionFailure.timeout }
    }

    static func wait(
        for commandBuffer: any MTLCommandBuffer,
        deadline: ContinuousClock.Instant
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.commit()
        while semaphore.wait(timeout: .now() + .milliseconds(2)) == .timedOut {
            try check(deadline)
        }
        guard commandBuffer.status == .completed else {
            throw R01ExecutionFailure.processing
        }
        try check(deadline)
    }
}

private struct R01ClosedNV12Fixture {
    let id: String
    let input: R01Dimensions
    let output: R01Dimensions?
    let luma: Data
    let chroma: Data

    init(context: R01LiveProbeContext, id: String, requiresOutput: Bool) throws {
        guard let payload = context.fixtures[id],
              payload.record.mediaKind == "nv12_frame",
              payload.record.pixelFormat == "420v",
              let input = payload.record.dimensions,
              input.width > 0, input.height > 0,
              input.width.isMultiple(of: 2), input.height.isMultiple(of: 2) else {
            throw R01ExecutionFailure.setup
        }
        let lumaCount = input.width * input.height
        guard payload.data.count == lumaCount + lumaCount / 2,
              !requiresOutput || payload.record.scaleOutput != nil else {
            throw R01ExecutionFailure.setup
        }
        self.id = id
        self.input = input
        output = payload.record.scaleOutput
        luma = payload.data.subdata(in: 0..<lumaCount)
        chroma = payload.data.subdata(in: lumaCount..<payload.data.count)
    }

    var nv12Data: Data {
        var result = luma
        result.append(chroma)
        return result
    }
}

private struct R01ClosedGrayFixture {
    let dimensions: R01Dimensions
    let data: Data

    init(context: R01LiveProbeContext, id: String) throws {
        guard let payload = context.fixtures[id],
              payload.record.mediaKind == "gray8_plane",
              payload.record.pixelFormat == "L008",
              let dimensions = payload.record.dimensions,
              payload.data.count == dimensions.width * dimensions.height else {
            throw R01ExecutionFailure.setup
        }
        self.dimensions = dimensions
        data = payload.data
    }
}

private enum R01LegacyMetrics {
    static let primary: [R01MetricName: R01MetricValue] = [:]

    static let support: [R01MetricName: R01MetricValue] = [
        .preservedDimensions: .string("1920x1080"),
        .preservedFormat: .string("420v"),
        .requiredGuidance: .boolean(true)
    ]

    static func combinedHash(_ labeledOutputs: [(String, Data)]) -> String {
        var record = Data()
        for (label, output) in labeledOutputs {
            record.append(Data(label.utf8))
            record.append(0)
            record.append(Data(R01SHA256.hexDigest(output).utf8))
            record.append(10)
        }
        return R01SHA256.hexDigest(record)
    }
}

private enum R01MetalTextureIO {
    static func texture(
        device: any MTLDevice,
        format: MTLPixelFormat,
        width: Int,
        height: Int,
        bytes: Data?,
        bytesPerRow: Int
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw R01ExecutionFailure.resource
        }
        if let bytes {
            guard bytes.count == bytesPerRow * height else {
                throw R01ExecutionFailure.setup
            }
            bytes.withUnsafeBytes { source in
                if let baseAddress = source.baseAddress {
                    texture.replace(
                        region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: baseAddress,
                        bytesPerRow: bytesPerRow
                    )
                }
            }
        }
        return texture
    }

    static func data(
        from texture: any MTLTexture,
        bytesPerPixel: Int
    ) throws -> Data {
        let bytesPerRow = texture.width * bytesPerPixel
        var output = Data(count: bytesPerRow * texture.height)
        output.withUnsafeMutableBytes { destination in
            if let baseAddress = destination.baseAddress {
                texture.getBytes(
                    baseAddress,
                    bytesPerRow: bytesPerRow,
                    from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                    mipmapLevel: 0
                )
            }
        }
        return output
    }
}

private final class R01MPSScaleRuntimeSession: R01CapabilityRuntimeSession {
    enum Method {
        case lanczos
        case bilinear
    }

    private struct PlanePair {
        let label: String
        let source: any MTLTexture
        let destination: any MTLTexture
        let bytesPerPixel: Int
        let kernel: MPSImageScale
    }

    private let commandQueue: any MTLCommandQueue
    private let pairs: [PlanePair]

    init(context: R01LiveProbeContext, method: Method) throws {
        guard let device = MTLCreateSystemDefaultDevice(), MPSSupportsMTLDevice(device),
              let commandQueue = device.makeCommandQueue() else {
            throw R01ExecutionFailure.resource
        }
        self.commandQueue = commandQueue
        var pairs: [PlanePair] = []
        for fixtureID in ["scaler-720p", "scaler-1080p"] {
            let fixture = try R01ClosedNV12Fixture(
                context: context,
                id: fixtureID,
                requiresOutput: true
            )
            guard let output = fixture.output else { throw R01ExecutionFailure.setup }
            pairs.append(try Self.makePair(
                device: device,
                method: method,
                label: "\(fixtureID):luma",
                format: .r8Unorm,
                input: fixture.input,
                output: output,
                bytes: fixture.luma,
                bytesPerPixel: 1
            ))
            pairs.append(try Self.makePair(
                device: device,
                method: method,
                label: "\(fixtureID):chroma",
                format: .rg8Unorm,
                input: .init(width: fixture.input.width / 2, height: fixture.input.height / 2),
                output: .init(width: output.width / 2, height: output.height / 2),
                bytes: fixture.chroma,
                bytesPerPixel: 2
            ))
        }
        self.pairs = pairs
    }

    func runUnit(deadline: ContinuousClock.Instant) throws -> R01RuntimeUnitResult {
        try R01LegacyDeadline.check(deadline)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw R01ExecutionFailure.resource
        }
        for pair in pairs {
            pair.kernel.encode(
                commandBuffer: commandBuffer,
                sourceTexture: pair.source,
                destinationTexture: pair.destination
            )
        }
        try R01LegacyDeadline.wait(for: commandBuffer, deadline: deadline)
        let outputs = try pairs.map { pair in
            try (pair.label, R01MetalTextureIO.data(
                from: pair.destination,
                bytesPerPixel: pair.bytesPerPixel
            ))
        }
        return .init(
            outputSHA256: R01LegacyMetrics.combinedHash(outputs),
            classMetrics: R01LegacyMetrics.primary,
            primaryScalerObservations: R01PrimaryScalerObservation.frozen
        )
    }

    private static func makePair(
        device: any MTLDevice,
        method: Method,
        label: String,
        format: MTLPixelFormat,
        input: R01Dimensions,
        output: R01Dimensions,
        bytes: Data,
        bytesPerPixel: Int
    ) throws -> PlanePair {
        let source = try R01MetalTextureIO.texture(
            device: device,
            format: format,
            width: input.width,
            height: input.height,
            bytes: bytes,
            bytesPerRow: input.width * bytesPerPixel
        )
        let destination = try R01MetalTextureIO.texture(
            device: device,
            format: format,
            width: output.width,
            height: output.height,
            bytes: nil,
            bytesPerRow: output.width * bytesPerPixel
        )
        let kernel: MPSImageScale = method == .lanczos
            ? MPSImageLanczosScale(device: device)
            : MPSImageBilinearScale(device: device)
        return .init(
            label: label,
            source: source,
            destination: destination,
            bytesPerPixel: bytesPerPixel,
            kernel: kernel
        )
    }
}

private final class R01MPSGroupedSupportRuntimeSession: R01CapabilityRuntimeSession {
    private let commandQueue: any MTLCommandQueue
    private let currentChroma: Data
    private let currentLuma: any MTLTexture
    private let guidance: any MTLTexture
    private let historyLuma: any MTLTexture
    private let coefficientsA: any MTLTexture
    private let coefficientsB: any MTLTexture
    private let guidedOutput: any MTLTexture
    private let detailOutput: any MTLTexture
    private let artifactOutput: any MTLTexture
    private let guidedFilter: MPSImageGuidedFilter
    private let laplacian: MPSImageLaplacian
    private let sobel: MPSImageSobel

    init(context: R01LiveProbeContext) throws {
        let current = try R01ClosedNV12Fixture(
            context: context,
            id: "support-frame",
            requiresOutput: false
        )
        let history = try R01ClosedNV12Fixture(
            context: context,
            id: "support-history",
            requiresOutput: false
        )
        let gray = try R01ClosedGrayFixture(context: context, id: "support-guidance")
        guard current.input == history.input, current.input == gray.dimensions,
              let device = MTLCreateSystemDefaultDevice(), MPSSupportsMTLDevice(device),
              let commandQueue = device.makeCommandQueue() else {
            throw R01ExecutionFailure.resource
        }
        self.commandQueue = commandQueue
        currentChroma = current.chroma
        currentLuma = try R01MetalTextureIO.texture(
            device: device, format: .r8Unorm,
            width: current.input.width, height: current.input.height,
            bytes: current.luma, bytesPerRow: current.input.width
        )
        historyLuma = try R01MetalTextureIO.texture(
            device: device, format: .r8Unorm,
            width: history.input.width, height: history.input.height,
            bytes: history.luma, bytesPerRow: history.input.width
        )
        guidance = try R01MetalTextureIO.texture(
            device: device, format: .rgba8Unorm,
            width: gray.dimensions.width, height: gray.dimensions.height,
            bytes: Self.rgbaGuidance(gray.data), bytesPerRow: gray.dimensions.width * 4
        )
        coefficientsA = try R01MetalTextureIO.texture(
            device: device, format: .rgba16Float,
            width: current.input.width, height: current.input.height,
            bytes: nil, bytesPerRow: current.input.width * 8
        )
        coefficientsB = try R01MetalTextureIO.texture(
            device: device, format: .rgba16Float,
            width: current.input.width, height: current.input.height,
            bytes: nil, bytesPerRow: current.input.width * 8
        )
        guidedOutput = try Self.r8Destination(device: device, dimensions: current.input)
        detailOutput = try Self.r8Destination(device: device, dimensions: current.input)
        artifactOutput = try Self.r8Destination(device: device, dimensions: current.input)
        guidedFilter = MPSImageGuidedFilter(device: device, kernelDiameter: 5)
        guidedFilter.epsilon = 0.01
        laplacian = MPSImageLaplacian(device: device)
        laplacian.bias = 0.5
        sobel = MPSImageSobel(device: device)
    }

    func runUnit(deadline: ContinuousClock.Instant) throws -> R01RuntimeUnitResult {
        try R01LegacyDeadline.check(deadline)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw R01ExecutionFailure.resource
        }
        guidedFilter.encodeRegression(
            commandBuffer: commandBuffer,
            source: currentLuma,
            guidance: guidance,
            weights: nil,
            destinationCoefficientsA: coefficientsA,
            destinationCoefficientsB: coefficientsB
        )
        guidedFilter.encodeReconstruction(
            commandBuffer: commandBuffer,
            guidance: guidance,
            coefficientsA: coefficientsA,
            coefficientsB: coefficientsB,
            destination: guidedOutput
        )
        laplacian.encode(
            commandBuffer: commandBuffer,
            sourceTexture: currentLuma,
            destinationTexture: detailOutput
        )
        sobel.encode(
            commandBuffer: commandBuffer,
            sourceTexture: historyLuma,
            destinationTexture: artifactOutput
        )
        try R01LegacyDeadline.wait(for: commandBuffer, deadline: deadline)
        var preservedNV12 = try R01MetalTextureIO.data(from: guidedOutput, bytesPerPixel: 1)
        preservedNV12.append(currentChroma)
        let outputs = try [
            ("guided:preserved-420v", preservedNV12),
            ("detail:laplacian", R01MetalTextureIO.data(from: detailOutput, bytesPerPixel: 1)),
            ("artifact:sobel-history", R01MetalTextureIO.data(from: artifactOutput, bytesPerPixel: 1))
        ]
        return .init(
            outputSHA256: R01LegacyMetrics.combinedHash(outputs),
            classMetrics: R01LegacyMetrics.support
        )
    }

    private static func r8Destination(
        device: any MTLDevice,
        dimensions: R01Dimensions
    ) throws -> any MTLTexture {
        try R01MetalTextureIO.texture(
            device: device, format: .r8Unorm,
            width: dimensions.width, height: dimensions.height,
            bytes: nil, bytesPerRow: dimensions.width
        )
    }

    private static func rgbaGuidance(_ gray: Data) -> Data {
        var result = Data(count: gray.count * 4)
        result.withUnsafeMutableBytes { destination in
            gray.withUnsafeBytes { source in
                let input = source.bindMemory(to: UInt8.self)
                let output = destination.bindMemory(to: UInt8.self)
                for index in input.indices {
                    let offset = index * 4
                    output[offset] = input[index]
                    output[offset + 1] = input[index]
                    output[offset + 2] = input[index]
                    output[offset + 3] = 255
                }
            }
        }
        return result
    }
}

private final class R01CoreImageScaleRuntimeSession: R01CapabilityRuntimeSession {
    private enum Method: String, CaseIterable {
        case lanczos
        case bicubic
    }

    private let context: CIContext
    private let fixtures: [R01ClosedNV12Fixture]

    init(context: R01LiveProbeContext) throws {
        fixtures = try ["scaler-720p", "scaler-1080p"].map {
            try R01ClosedNV12Fixture(context: context, id: $0, requiresOutput: true)
        }
        self.context = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false
        ])
    }

    func runUnit(deadline: ContinuousClock.Instant) throws -> R01RuntimeUnitResult {
        var outputs: [(String, Data)] = []
        for method in Method.allCases {
            for fixture in fixtures {
                try R01LegacyDeadline.check(deadline)
                guard let output = fixture.output else { throw R01ExecutionFailure.setup }
                var nv12 = try scalePlane(
                    fixture.luma,
                    input: fixture.input,
                    output: output,
                    format: .L8,
                    bytesPerPixel: 1,
                    method: method
                )
                nv12.append(try scalePlane(
                    fixture.chroma,
                    input: .init(
                        width: fixture.input.width / 2,
                        height: fixture.input.height / 2
                    ),
                    output: .init(width: output.width / 2, height: output.height / 2),
                    format: .RG8,
                    bytesPerPixel: 2,
                    method: method
                ))
                outputs.append(("\(method.rawValue):\(fixture.id):420v", nv12))
                try R01LegacyDeadline.check(deadline)
            }
        }
        return .init(
            outputSHA256: R01LegacyMetrics.combinedHash(outputs),
            classMetrics: R01LegacyMetrics.primary,
            primaryScalerObservations: R01PrimaryScalerObservation.frozen
        )
    }

    private func scalePlane(
        _ sourceData: Data,
        input: R01Dimensions,
        output: R01Dimensions,
        format: CIFormat,
        bytesPerPixel: Int,
        method: Method
    ) throws -> Data {
        let inputImage = CIImage(
            bitmapData: sourceData,
            bytesPerRow: input.width * bytesPerPixel,
            size: CGSize(width: input.width, height: input.height),
            format: format,
            colorSpace: nil
        )
        let scale = Float(output.height) / Float(input.height)
        let expectedHorizontalScale = Float(output.width) / Float(input.width)
        guard scale == expectedHorizontalScale else { throw R01ExecutionFailure.setup }

        let filtered: CIImage?
        switch method {
        case .lanczos:
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = inputImage
            filter.scale = scale
            filter.aspectRatio = 1
            filtered = filter.outputImage
        case .bicubic:
            let filter = CIFilter.bicubicScaleTransform()
            filter.inputImage = inputImage
            filter.scale = scale
            filter.aspectRatio = 1
            filter.parameterB = 0
            filter.parameterC = 0.75
            filtered = filter.outputImage
        }
        guard let filtered else { throw R01ExecutionFailure.processing }
        let bounds = CGRect(x: 0, y: 0, width: output.width, height: output.height)
        var result = Data(count: output.width * output.height * bytesPerPixel)
        result.withUnsafeMutableBytes { destination in
            if let baseAddress = destination.baseAddress {
                context.render(
                    filtered.cropped(to: bounds),
                    toBitmap: baseAddress,
                    rowBytes: output.width * bytesPerPixel,
                    bounds: bounds,
                    format: format,
                    colorSpace: nil
                )
            }
        }
        return result
    }
}

private func r01VImageCustomKernel(
    _ xArray: UnsafePointer<Float>?,
    _ yArray: UnsafeMutablePointer<Float>?,
    _ count: UInt,
    _ userData: UnsafeMutableRawPointer?
) {
    _ = userData
    guard let xArray, let yArray, count > 0 else { return }
    var sum: Float = 0
    for index in 0..<Int(count) {
        let xValue = xArray[index]
        let absolute = abs(xValue)
        let value: Float
        if absolute < 0.000_001 {
            value = 1
        } else if absolute >= 2 {
            value = 0
        } else {
            let first = sin(.pi * xValue) / (.pi * xValue)
            let second = sin(.pi * xValue / 2) / (.pi * xValue / 2)
            value = first * second
        }
        yArray[index] = value
        sum += value
    }
    guard abs(sum) > 0.000_001 else { return }
    for index in 0..<Int(count) {
        yArray[index] /= sum
    }
}

private final class R01VImageCustomFilter {
    let filter: UnsafeMutablePointer<ResamplingFilter>
    private let storage: UnsafeMutableRawPointer

    init(scale: Float) throws {
        let flags = vImage_Flags(kvImageNoFlags)
        let byteCount = vImageGetResamplingFilterSize(
            scale,
            r01VImageCustomKernel,
            2,
            flags
        )
        guard byteCount > 0 else { throw R01ExecutionFailure.resource }
        storage = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        filter = storage.assumingMemoryBound(to: ResamplingFilter.self)
        let status = vImageNewResamplingFilterForFunctionUsingBuffer(
            filter,
            scale,
            r01VImageCustomKernel,
            2,
            nil,
            flags
        )
        guard status == kvImageNoError else {
            storage.deallocate()
            throw R01ExecutionFailure.setup
        }
    }

    deinit {
        storage.deallocate()
    }
}

private final class R01VImageScaleRuntimeSession: R01CapabilityRuntimeSession {
    private struct Fixture {
        let value: R01ClosedNV12Fixture
        let customFilter: R01VImageCustomFilter
    }

    private let fixtures: [Fixture]

    init(context: R01LiveProbeContext) throws {
        fixtures = try ["scaler-720p", "scaler-1080p"].map { id in
            let fixture = try R01ClosedNV12Fixture(
                context: context,
                id: id,
                requiresOutput: true
            )
            guard let output = fixture.output else { throw R01ExecutionFailure.setup }
            let horizontalScale = Float(output.width) / Float(fixture.input.width)
            let verticalScale = Float(output.height) / Float(fixture.input.height)
            guard horizontalScale == verticalScale else { throw R01ExecutionFailure.setup }
            return Fixture(
                value: fixture,
                customFilter: try R01VImageCustomFilter(scale: horizontalScale)
            )
        }
    }

    func runUnit(deadline: ContinuousClock.Instant) throws -> R01RuntimeUnitResult {
        var outputs: [(String, Data)] = []
        for fixture in fixtures {
            try R01LegacyDeadline.check(deadline)
            outputs.append((
                "lanczos-3:\(fixture.value.id):420v",
                try scaleNV12(fixture.value, flags: vImage_Flags(kvImageEdgeExtend))
            ))
            try R01LegacyDeadline.check(deadline)
            outputs.append((
                "lanczos-5:\(fixture.value.id):420v",
                try scaleNV12(
                    fixture.value,
                    flags: vImage_Flags(kvImageEdgeExtend | kvImageHighQualityResampling)
                )
            ))
            try R01LegacyDeadline.check(deadline)
            outputs.append((
                "custom-lanczos-2:\(fixture.value.id):420v",
                try customScaleNV12(fixture.value, filter: fixture.customFilter.filter)
            ))
            try R01LegacyDeadline.check(deadline)
        }
        return .init(
            outputSHA256: R01LegacyMetrics.combinedHash(outputs),
            classMetrics: R01LegacyMetrics.primary,
            primaryScalerObservations: R01PrimaryScalerObservation.frozen
        )
    }

    private func scaleNV12(
        _ fixture: R01ClosedNV12Fixture,
        flags: vImage_Flags
    ) throws -> Data {
        guard let output = fixture.output else { throw R01ExecutionFailure.setup }
        var lumaOutput = Data(count: output.width * output.height)
        var chromaOutput = Data(count: output.width * output.height / 2)
        let lumaStatus = fixture.luma.withUnsafeBytes { sourceBytes in
            lumaOutput.withUnsafeMutableBytes { destinationBytes -> vImage_Error in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBytes.baseAddress),
                    height: vImagePixelCount(fixture.input.height),
                    width: vImagePixelCount(fixture.input.width),
                    rowBytes: fixture.input.width
                )
                var destination = vImage_Buffer(
                    data: destinationBytes.baseAddress,
                    height: vImagePixelCount(output.height),
                    width: vImagePixelCount(output.width),
                    rowBytes: output.width
                )
                return vImageScale_Planar8(&source, &destination, nil, flags)
            }
        }
        let chromaStatus = fixture.chroma.withUnsafeBytes { sourceBytes in
            chromaOutput.withUnsafeMutableBytes { destinationBytes -> vImage_Error in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBytes.baseAddress),
                    height: vImagePixelCount(fixture.input.height / 2),
                    width: vImagePixelCount(fixture.input.width / 2),
                    rowBytes: fixture.input.width
                )
                var destination = vImage_Buffer(
                    data: destinationBytes.baseAddress,
                    height: vImagePixelCount(output.height / 2),
                    width: vImagePixelCount(output.width / 2),
                    rowBytes: output.width
                )
                return vImageScale_CbCr8(&source, &destination, nil, flags)
            }
        }
        guard lumaStatus == kvImageNoError, chromaStatus == kvImageNoError else {
            throw R01ExecutionFailure.processing
        }
        lumaOutput.append(chromaOutput)
        return lumaOutput
    }

    private func customScaleNV12(
        _ fixture: R01ClosedNV12Fixture,
        filter: UnsafeMutablePointer<ResamplingFilter>
    ) throws -> Data {
        guard let output = fixture.output else { throw R01ExecutionFailure.setup }
        var result = try customScalePlane(
            fixture.luma,
            input: fixture.input,
            output: output,
            filter: filter
        )
        let chromaInput = Self.splitChroma(
            fixture.chroma,
            pixelCount: fixture.input.width * fixture.input.height / 4
        )
        let chromaDimensions = R01Dimensions(
            width: fixture.input.width / 2,
            height: fixture.input.height / 2
        )
        let chromaOutputDimensions = R01Dimensions(
            width: output.width / 2,
            height: output.height / 2
        )
        let cb = try customScalePlane(
            chromaInput.cb,
            input: chromaDimensions,
            output: chromaOutputDimensions,
            filter: filter
        )
        let cr = try customScalePlane(
            chromaInput.cr,
            input: chromaDimensions,
            output: chromaOutputDimensions,
            filter: filter
        )
        result.append(Self.interleaveChroma(cb: cb, cr: cr))
        return result
    }

    private func customScalePlane(
        _ sourceData: Data,
        input: R01Dimensions,
        output: R01Dimensions,
        filter: UnsafeMutablePointer<ResamplingFilter>
    ) throws -> Data {
        var intermediate = Data(count: output.width * input.height)
        var destination = Data(count: output.width * output.height)
        let horizontalStatus = sourceData.withUnsafeBytes { sourceBytes in
            intermediate.withUnsafeMutableBytes { intermediateBytes -> vImage_Error in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBytes.baseAddress),
                    height: vImagePixelCount(input.height),
                    width: vImagePixelCount(input.width),
                    rowBytes: input.width
                )
                var target = vImage_Buffer(
                    data: intermediateBytes.baseAddress,
                    height: vImagePixelCount(input.height),
                    width: vImagePixelCount(output.width),
                    rowBytes: output.width
                )
                return vImageHorizontalShear_Planar8(
                    &source, &target, 0, 0, 0, 0, filter, 0,
                    vImage_Flags(kvImageEdgeExtend)
                )
            }
        }
        guard horizontalStatus == kvImageNoError else {
            throw R01ExecutionFailure.processing
        }
        let verticalStatus = intermediate.withUnsafeBytes { intermediateBytes in
            destination.withUnsafeMutableBytes { destinationBytes -> vImage_Error in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: intermediateBytes.baseAddress),
                    height: vImagePixelCount(input.height),
                    width: vImagePixelCount(output.width),
                    rowBytes: output.width
                )
                var target = vImage_Buffer(
                    data: destinationBytes.baseAddress,
                    height: vImagePixelCount(output.height),
                    width: vImagePixelCount(output.width),
                    rowBytes: output.width
                )
                return vImageVerticalShear_Planar8(
                    &source, &target, 0, 0, 0, 0, filter, 0,
                    vImage_Flags(kvImageEdgeExtend)
                )
            }
        }
        guard verticalStatus == kvImageNoError else {
            throw R01ExecutionFailure.processing
        }
        return destination
    }

    private static func splitChroma(
        _ data: Data,
        pixelCount: Int
    ) -> (cb: Data, cr: Data) {
        var cb = Data(count: pixelCount)
        var cr = Data(count: pixelCount)
        data.withUnsafeBytes { sourceBytes in
            cb.withUnsafeMutableBytes { cbBytes in
                cr.withUnsafeMutableBytes { crBytes in
                    let source = sourceBytes.bindMemory(to: UInt8.self)
                    let cbOutput = cbBytes.bindMemory(to: UInt8.self)
                    let crOutput = crBytes.bindMemory(to: UInt8.self)
                    for index in 0..<pixelCount {
                        cbOutput[index] = source[index * 2]
                        crOutput[index] = source[index * 2 + 1]
                    }
                }
            }
        }
        return (cb, cr)
    }

    private static func interleaveChroma(cb: Data, cr: Data) -> Data {
        precondition(cb.count == cr.count)
        var result = Data(count: cb.count * 2)
        result.withUnsafeMutableBytes { destinationBytes in
            cb.withUnsafeBytes { cbBytes in
                cr.withUnsafeBytes { crBytes in
                    let output = destinationBytes.bindMemory(to: UInt8.self)
                    let cbInput = cbBytes.bindMemory(to: UInt8.self)
                    let crInput = crBytes.bindMemory(to: UInt8.self)
                    for index in 0..<cb.count {
                        output[index * 2] = cbInput[index]
                        output[index * 2 + 1] = crInput[index]
                    }
                }
            }
        }
        return result
    }
}

private final class R01MetalSupportRuntimeSession: R01CapabilityRuntimeSession {
    private static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void r01_support_filter(
        device const uchar *current [[buffer(0)]],
        device const uchar *guidance [[buffer(1)]],
        device const uchar *history [[buffer(2)]],
        device uchar *output [[buffer(3)]],
        constant uint &lumaCount [[buffer(4)]],
        constant uint &byteCount [[buffer(5)]],
        uint index [[thread_position_in_grid]]) {
        if (index >= byteCount) { return; }
        if (index < lumaCount) {
            uint value = uint(current[index]) * 2u
                + uint(guidance[index]) + uint(history[index]) + 2u;
            output[index] = uchar(value / 4u);
        } else {
            uint value = uint(current[index]) + uint(history[index]) + 1u;
            output[index] = uchar(value / 2u);
        }
    }
    """

    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let current: any MTLBuffer
    private let guidance: any MTLBuffer
    private let history: any MTLBuffer
    private let output: any MTLBuffer
    private let lumaCount: UInt32
    private let byteCount: UInt32

    init(context: R01LiveProbeContext) throws {
        let currentFixture = try R01ClosedNV12Fixture(
            context: context,
            id: "support-frame",
            requiresOutput: false
        )
        let historyFixture = try R01ClosedNV12Fixture(
            context: context,
            id: "support-history",
            requiresOutput: false
        )
        let guidanceFixture = try R01ClosedGrayFixture(
            context: context,
            id: "support-guidance"
        )
        guard currentFixture.input == historyFixture.input,
              currentFixture.input == guidanceFixture.dimensions,
              currentFixture.nv12Data.count == historyFixture.nv12Data.count,
              currentFixture.luma.count <= UInt32.max,
              currentFixture.nv12Data.count <= UInt32.max,
              let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw R01ExecutionFailure.resource
        }
        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.kernelSource, options: nil)
        } catch {
            throw R01ExecutionFailure.setup
        }
        guard let function = library.makeFunction(name: "r01_support_filter") else {
            throw R01ExecutionFailure.setup
        }
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw R01ExecutionFailure.setup
        }
        self.commandQueue = commandQueue
        let currentData = currentFixture.nv12Data
        let historyData = historyFixture.nv12Data
        guard let current = Self.buffer(device: device, data: currentData),
              let history = Self.buffer(device: device, data: historyData),
              let guidance = Self.buffer(device: device, data: guidanceFixture.data),
              let output = device.makeBuffer(
                length: currentData.count,
                options: .storageModeShared
              ) else {
            throw R01ExecutionFailure.resource
        }
        self.current = current
        self.guidance = guidance
        self.history = history
        self.output = output
        lumaCount = UInt32(currentFixture.luma.count)
        byteCount = UInt32(currentData.count)
    }

    func runUnit(deadline: ContinuousClock.Instant) throws -> R01RuntimeUnitResult {
        try R01LegacyDeadline.check(deadline)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw R01ExecutionFailure.resource
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(current, offset: 0, index: 0)
        encoder.setBuffer(guidance, offset: 0, index: 1)
        encoder.setBuffer(history, offset: 0, index: 2)
        encoder.setBuffer(output, offset: 0, index: 3)
        var lumaCount = lumaCount
        var byteCount = byteCount
        encoder.setBytes(&lumaCount, length: MemoryLayout<UInt32>.size, index: 4)
        encoder.setBytes(&byteCount, length: MemoryLayout<UInt32>.size, index: 5)
        let threadWidth = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(
            MTLSize(width: Int(byteCount), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: 1, depth: 1)
        )
        encoder.endEncoding()
        try R01LegacyDeadline.wait(for: commandBuffer, deadline: deadline)
        let bytes = Data(bytes: output.contents(), count: Int(byteCount))
        return .init(
            outputSHA256: R01LegacyMetrics.combinedHash([
                ("custom-metal:support-frame+guidance+history:420v", bytes)
            ]),
            classMetrics: R01LegacyMetrics.support
        )
    }

    private static func buffer(
        device: any MTLDevice,
        data: Data
    ) -> (any MTLBuffer)? {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: data.count,
                options: .storageModeShared
            )
        }
    }
}

// swiftlint:enable file_length
