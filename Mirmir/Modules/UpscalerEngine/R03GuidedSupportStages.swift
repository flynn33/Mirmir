import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders

// swiftlint:disable file_length

enum R03SupportStageConstructionError: Error, Equatable, Sendable {
    case subjectIsNotSupportStage(R03BaselineSubjectID)
    case routeNotPreregistered(
        subject: R03BaselineSubjectID,
        route: R03BaselineRouteID
    )
}

struct R03SupportImageContract: Hashable, Sendable {
    let pixelFormat: OSType
    let width: Int
    let height: Int
}

struct R03SupportStageContract: Hashable, Sendable {
    let subjectID: R03BaselineSubjectID
    let routeID: R03BaselineRouteID
    let source: R03SupportImageContract
    let guidance: R03SupportImageContract
    let output: R03SupportImageContract
    let configurationIdentity: String

    static let mpsGuidedFilter = R03SupportStageContract(
        subjectID: .mpsGuidedFilter,
        routeID: .guidedSupport1x,
        source: .init(
            pixelFormat: kCVPixelFormatType_OneComponent8,
            width: 64,
            height: 64
        ),
        guidance: .init(
            pixelFormat: kCVPixelFormatType_OneComponent8,
            width: 64,
            height: 64
        ),
        output: .init(
            pixelFormat: kCVPixelFormatType_OneComponent8,
            width: 64,
            height: 64
        ),
        configurationIdentity:
            "r03.mps.guided-filter.guided_support_1x.r8-to-rgba8-rgba16f.k5-e0p01.v1"
    )

    static let coreImageEdgePreserve = R03SupportStageContract(
        subjectID: .coreImageEdgePreserve,
        routeID: .edgePreserveSupport2x,
        source: .init(
            pixelFormat: kCVPixelFormatType_OneComponent8,
            width: 32,
            height: 32
        ),
        guidance: .init(
            pixelFormat: kCVPixelFormatType_OneComponent8,
            width: 64,
            height: 64
        ),
        output: .init(
            pixelFormat: kCVPixelFormatType_OneComponent8,
            width: 64,
            height: 64
        ),
        configurationIdentity:
            "r03.core-image.edge-preserve.edge_preserve_support_2x.r8.s3-l0p15.v1"
    )
}

enum R03SupportStageParameters {
    static let guidedFilterKernelDiameter = 5
    static let guidedFilterEpsilon: Float = 0.01
    static let edgePreserveSpatialSigma: Float = 3
    static let edgePreserveLumaSigma: Float = 0.15
}

struct R03SupportStageInput: @unchecked Sendable {
    let source: CVPixelBuffer
    let guidance: CVPixelBuffer
}

struct R03SupportStageOutput: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let processingIdentity: AppleUpscaleProcessingIdentity
}

protocol R03SupportStage: AnyObject, Sendable {
    var subjectID: R03BaselineSubjectID { get }
    var processingIdentity: AppleUpscaleProcessingIdentity { get }

    func process(
        _ input: R03SupportStageInput,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) -> AppleUpscaleBackendOutcome<R03SupportStageOutput>
}

enum R03SupportStageCreationOutcome: Sendable {
    case created(any R03SupportStage)
    case unavailable(AppleUpscaleBackendUnavailable)
    case rejected(AppleUpscaleBackendRejected)
    case failed(AppleUpscaleBackendFailed)
}

enum R03SupportStageFactory {
    static func makeMPSGuidedFilter(
        context: AppleUpscaleSessionContext
    ) throws -> R03SupportStageCreationOutcome {
        let admission = try R03SupportStageAdmission(
            contract: .mpsGuidedFilter
        )
        if let denial = admission.denial(for: context) {
            return denial.creationOutcome
        }
        do {
            return .created(
                try R03MPSGuidedFilterSupportStage(admission: admission)
            )
        } catch R03SupportStageExecutionError.runtimeUnavailable {
            return .unavailable(admission.runtimeUnavailable)
        } catch {
            return .failed(admission.creationFailed)
        }
    }

    static func makeCoreImageEdgePreserve(
        context: AppleUpscaleSessionContext
    ) throws -> R03SupportStageCreationOutcome {
        let admission = try R03SupportStageAdmission(
            contract: .coreImageEdgePreserve
        )
        if let denial = admission.denial(for: context) {
            return denial.creationOutcome
        }
        return .created(
            try R03CoreImageEdgePreserveSupportStage(admission: admission)
        )
    }
}

private enum R03SupportStageAdmissionDenial {
    case unavailable(AppleUpscaleBackendUnavailable)
    case rejected(AppleUpscaleBackendRejected)

    var creationOutcome: R03SupportStageCreationOutcome {
        switch self {
        case .unavailable(let unavailable):
            return .unavailable(unavailable)
        case .rejected(let rejected):
            return .rejected(rejected)
        }
    }
}

private struct R03SupportStageAdmission: Sendable {
    let contract: R03SupportStageContract
    let subject: R03BaselineSubjectDescriptor
    let capabilityID: AppleUpscaleCapabilityID
    let processingIdentity: AppleUpscaleProcessingIdentity
    let contractRejected: AppleUpscaleBackendRejected
    let capabilityUnavailable: AppleUpscaleBackendUnavailable
    let runtimeUnavailable: AppleUpscaleBackendUnavailable
    let creationFailed: AppleUpscaleBackendFailed

    init(contract: R03SupportStageContract) throws {
        guard let subject = R03DeterministicBackendCatalog.subject(
            contract.subjectID
        ), subject.kind == .supportStage,
            subject.productDefaultEligibility == .ineligibleSupportStage else {
            throw R03SupportStageConstructionError.subjectIsNotSupportStage(
                contract.subjectID
            )
        }
        guard subject.routeIDs == [contract.routeID] else {
            throw R03SupportStageConstructionError.routeNotPreregistered(
                subject: contract.subjectID,
                route: contract.routeID
            )
        }

        let backendIdentity = try AppleUpscaleBackendIdentity(
            backendID: subject.id.rawValue,
            backendRevision: R03DeterministicBackendCatalog.backendRevision,
            modelAssetsIdentity: .notRequired
        )
        let routeIdentity = try AppleUpscaleRouteIdentity(
            backend: backendIdentity,
            configurationIdentity: contract.configurationIdentity,
            policyIdentity: R03DeterministicBackendCatalog.policyIdentity,
            materialDecisionIdentity:
                R03DeterministicBackendCatalog.materialDecisionIdentity
        )
        let processingIdentity = try AppleUpscaleProcessingIdentity(
            route: routeIdentity,
            fallbackHistory: []
        )

        self.contract = contract
        self.subject = subject
        capabilityID = try AppleUpscaleCapabilityID(subject.capabilityID)
        self.processingIdentity = processingIdentity
        contractRejected = try AppleUpscaleBackendRejected(
            processingIdentity: processingIdentity,
            reason: "r03_support_stage_contract_mismatch"
        )
        capabilityUnavailable = try AppleUpscaleBackendUnavailable(
            processingIdentity: processingIdentity,
            reason: "r03_support_stage_capability_unavailable"
        )
        runtimeUnavailable = try AppleUpscaleBackendUnavailable(
            processingIdentity: processingIdentity,
            reason: "r03_support_stage_runtime_unavailable"
        )
        creationFailed = try AppleUpscaleBackendFailed(
            processingIdentity: processingIdentity,
            reason: "r03_support_stage_creation_failed"
        )
    }

    func denial(
        for context: AppleUpscaleSessionContext
    ) -> R03SupportStageAdmissionDenial? {
        guard context.admissionScope == .fixtureOnly,
              context.policyIdentity == R03DeterministicBackendCatalog.policyIdentity else {
            return .rejected(contractRejected)
        }
        guard let capability = context.capabilityRegistry.capability(
            for: capabilityID
        ) else {
            return .unavailable(capabilityUnavailable)
        }
        guard capability.role == .supportFilter,
              capability.frameworkIdentity == subject.frameworkIdentity else {
            return .rejected(contractRejected)
        }
        guard capability.observationStatus == .observed,
              capability.runtimeDisposition == .runnable else {
            return .unavailable(capabilityUnavailable)
        }
        guard capability.backendEligibility == .fixtureOnly,
              capability.isEligible(for: .fixtureOnly) else {
            return .rejected(contractRejected)
        }
        return nil
    }
}

private enum R03SupportStageExecutionError: Error, Equatable, Sendable {
    case runtimeUnavailable
    case invalidPixelFormat(expected: OSType, actual: OSType)
    case invalidDimensions(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case nonPlanarBuffer
    case pixelBufferCreationFailed(CVReturn)
    case pixelBufferLockFailed(CVReturn)
    case missingBaseAddress
    case metalResourceCreationFailed
    case commandBufferFailed(Int)
    case coreImageOutputMissing
    case operationCancelled
}

private class R03SupportStageBase: @unchecked Sendable {
    let subjectID: R03BaselineSubjectID
    let processingIdentity: AppleUpscaleProcessingIdentity
    let contract: R03SupportStageContract

    private let cancellationRejected: AppleUpscaleBackendRejected
    private let inputRejected: AppleUpscaleBackendRejected
    private let runtimeUnavailable: AppleUpscaleBackendUnavailable
    private let processingFailed: AppleUpscaleBackendFailed

    init(admission: R03SupportStageAdmission) throws {
        subjectID = admission.subject.id
        processingIdentity = admission.processingIdentity
        contract = admission.contract
        cancellationRejected = try AppleUpscaleBackendRejected(
            processingIdentity: admission.processingIdentity,
            reason: "operation_cancelled"
        )
        inputRejected = try AppleUpscaleBackendRejected(
            processingIdentity: admission.processingIdentity,
            reason: "r03_support_stage_input_contract_mismatch"
        )
        runtimeUnavailable = admission.runtimeUnavailable
        processingFailed = try AppleUpscaleBackendFailed(
            processingIdentity: admission.processingIdentity,
            reason: "r03_support_stage_processing_failed"
        )
    }

    final func rejectCancellation() -> AppleUpscaleBackendOutcome<R03SupportStageOutput> {
        .rejected(cancellationRejected)
    }

    final func rejectInput() -> AppleUpscaleBackendOutcome<R03SupportStageOutput> {
        .rejected(inputRejected)
    }

    final func unavailable() -> AppleUpscaleBackendOutcome<R03SupportStageOutput> {
        .unavailable(runtimeUnavailable)
    }

    final func fail() -> AppleUpscaleBackendOutcome<R03SupportStageOutput> {
        .failed(processingFailed)
    }

    final func processed(
        _ pixelBuffer: CVPixelBuffer
    ) -> AppleUpscaleBackendOutcome<R03SupportStageOutput> {
        .processed(
            R03SupportStageOutput(
                pixelBuffer: pixelBuffer,
                processingIdentity: processingIdentity
            )
        )
    }
}

private final class R03MPSGuidedFilterSupportStage: R03SupportStageBase,
    R03SupportStage, @unchecked Sendable {
    private let lock = NSLock()
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let guidedFilter: MPSImageGuidedFilter

    override init(admission: R03SupportStageAdmission) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              MPSSupportsMTLDevice(device),
              let commandQueue = device.makeCommandQueue() else {
            throw R03SupportStageExecutionError.runtimeUnavailable
        }
        self.device = device
        self.commandQueue = commandQueue
        guidedFilter = MPSImageGuidedFilter(
            device: device,
            kernelDiameter: R03SupportStageParameters.guidedFilterKernelDiameter
        )
        guidedFilter.epsilon = R03SupportStageParameters.guidedFilterEpsilon
        try super.init(admission: admission)
    }

    func process(
        _ input: R03SupportStageInput,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) -> AppleUpscaleBackendOutcome<R03SupportStageOutput> {
        guard !cancellation.isCancelled else { return rejectCancellation() }
        do {
            try R03SupportPixelBuffer.validate(
                input.source,
                contract: contract.source
            )
            try R03SupportPixelBuffer.validate(
                input.guidance,
                contract: contract.guidance
            )
        } catch {
            return rejectInput()
        }

        do {
            let output = try execute(input, cancellation: cancellation)
            return processed(output)
        } catch R03SupportStageExecutionError.operationCancelled {
            return rejectCancellation()
        } catch R03SupportStageExecutionError.runtimeUnavailable {
            return unavailable()
        } catch {
            return fail()
        }
    }

    private func execute(
        _ input: R03SupportStageInput,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) throws -> CVPixelBuffer {
        let sourceData = try R03SupportPixelBuffer.read(
            input.source,
            bytesPerPixel: 1
        )
        let guidanceData = try R03SupportPixelBuffer.read(
            input.guidance,
            bytesPerPixel: 1
        )
        let rgbaGuidance = Self.expandGuidanceToRGBA(guidanceData)
        guard !cancellation.isCancelled else {
            throw R03SupportStageExecutionError.operationCancelled
        }

        lock.lock()
        defer { lock.unlock() }
        guard !cancellation.isCancelled else {
            throw R03SupportStageExecutionError.operationCancelled
        }
        let source = try makeTexture(
            format: .r8Unorm,
            width: 64,
            height: 64,
            bytes: sourceData,
            bytesPerRow: 64
        )
        let guidance = try makeTexture(
            format: .rgba8Unorm,
            width: 64,
            height: 64,
            bytes: rgbaGuidance,
            bytesPerRow: 256
        )
        let coefficientsA = try makeTexture(
            format: .rgba16Float,
            width: 64,
            height: 64
        )
        let coefficientsB = try makeTexture(
            format: .rgba16Float,
            width: 64,
            height: 64
        )
        let destination = try makeTexture(
            format: .r8Unorm,
            width: 64,
            height: 64
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw R03SupportStageExecutionError.metalResourceCreationFailed
        }
        guidedFilter.encodeRegression(
            commandBuffer: commandBuffer,
            source: source,
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
            destination: destination
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw R03SupportStageExecutionError.commandBufferFailed(
                Int(commandBuffer.status.rawValue)
            )
        }
        guard !cancellation.isCancelled else {
            throw R03SupportStageExecutionError.operationCancelled
        }

        var outputData = Data(count: 64 * 64)
        outputData.withUnsafeMutableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                destination.getBytes(
                    baseAddress,
                    bytesPerRow: 64,
                    from: MTLRegionMake2D(0, 0, 64, 64),
                    mipmapLevel: 0
                )
            }
        }
        let output = try R03SupportPixelBuffer.make(contract: contract.output)
        try R03SupportPixelBuffer.write(outputData, to: output, bytesPerPixel: 1)
        return output
    }

    private static func expandGuidanceToRGBA(_ gray: Data) -> Data {
        var rgba = Data(count: gray.count * 4)
        gray.withUnsafeBytes { source in
            rgba.withUnsafeMutableBytes { destination in
                guard let sourceBase = source.baseAddress?.assumingMemoryBound(
                    to: UInt8.self
                ), let destinationBase = destination.baseAddress?.assumingMemoryBound(
                    to: UInt8.self
                ) else { return }
                for index in 0..<gray.count {
                    let value = sourceBase[index]
                    destinationBase[index * 4] = value
                    destinationBase[index * 4 + 1] = value
                    destinationBase[index * 4 + 2] = value
                    destinationBase[index * 4 + 3] = 255
                }
            }
        }
        return rgba
    }

    private func makeTexture(
        format: MTLPixelFormat,
        width: Int,
        height: Int,
        bytes: Data? = nil,
        bytesPerRow: Int = 0
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw R03SupportStageExecutionError.metalResourceCreationFailed
        }
        if let bytes {
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
}

private final class R03CoreImageEdgePreserveSupportStage: R03SupportStageBase,
    R03SupportStage, @unchecked Sendable {
    private let lock = NSLock()
    private let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false
    ])

    func process(
        _ input: R03SupportStageInput,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) -> AppleUpscaleBackendOutcome<R03SupportStageOutput> {
        guard !cancellation.isCancelled else { return rejectCancellation() }
        do {
            try R03SupportPixelBuffer.validate(
                input.source,
                contract: contract.source
            )
            try R03SupportPixelBuffer.validate(
                input.guidance,
                contract: contract.guidance
            )
        } catch {
            return rejectInput()
        }

        do {
            let output = try execute(input, cancellation: cancellation)
            return processed(output)
        } catch R03SupportStageExecutionError.operationCancelled {
            return rejectCancellation()
        } catch {
            return fail()
        }
    }

    private func execute(
        _ input: R03SupportStageInput,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) throws -> CVPixelBuffer {
        let maskData = try R03SupportPixelBuffer.read(
            input.source,
            bytesPerPixel: 1
        )
        let guidanceData = try R03SupportPixelBuffer.read(
            input.guidance,
            bytesPerPixel: 1
        )
        guard !cancellation.isCancelled else {
            throw R03SupportStageExecutionError.operationCancelled
        }

        lock.lock()
        defer { lock.unlock() }
        let mask = CIImage(
            bitmapData: maskData,
            bytesPerRow: 32,
            size: CGSize(width: 32, height: 32),
            format: .L8,
            colorSpace: nil
        )
        let guidance = CIImage(
            bitmapData: guidanceData,
            bytesPerRow: 64,
            size: CGSize(width: 64, height: 64),
            format: .L8,
            colorSpace: nil
        )
        let filter = CIFilter.edgePreserveUpsample()
        filter.smallImage = mask
        filter.inputImage = guidance
        filter.spatialSigma = R03SupportStageParameters.edgePreserveSpatialSigma
        filter.lumaSigma = R03SupportStageParameters.edgePreserveLumaSigma
        guard let filtered = filter.outputImage else {
            throw R03SupportStageExecutionError.coreImageOutputMissing
        }
        guard !cancellation.isCancelled else {
            throw R03SupportStageExecutionError.operationCancelled
        }

        let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        var outputData = Data(count: 64 * 64)
        outputData.withUnsafeMutableBytes { destination in
            if let baseAddress = destination.baseAddress {
                context.render(
                    filtered.cropped(to: bounds),
                    toBitmap: baseAddress,
                    rowBytes: 64,
                    bounds: bounds,
                    format: .L8,
                    colorSpace: nil
                )
            }
        }
        guard !cancellation.isCancelled else {
            throw R03SupportStageExecutionError.operationCancelled
        }
        let output = try R03SupportPixelBuffer.make(contract: contract.output)
        try R03SupportPixelBuffer.write(outputData, to: output, bytesPerPixel: 1)
        return output
    }
}

private enum R03SupportPixelBuffer {
    static func validate(
        _ pixelBuffer: CVPixelBuffer,
        contract: R03SupportImageContract
    ) throws {
        let actualFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard actualFormat == contract.pixelFormat else {
            throw R03SupportStageExecutionError.invalidPixelFormat(
                expected: contract.pixelFormat,
                actual: actualFormat
            )
        }
        let actualWidth = CVPixelBufferGetWidth(pixelBuffer)
        let actualHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard actualWidth == contract.width, actualHeight == contract.height else {
            throw R03SupportStageExecutionError.invalidDimensions(
                expectedWidth: contract.width,
                expectedHeight: contract.height,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 0 else {
            throw R03SupportStageExecutionError.nonPlanarBuffer
        }
    }

    static func make(
        contract: R03SupportImageContract
    ) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            contract.width,
            contract.height,
            contract.pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw R03SupportStageExecutionError.pixelBufferCreationFailed(status)
        }
        return pixelBuffer
    }

    static func read(
        _ pixelBuffer: CVPixelBuffer,
        bytesPerPixel: Int
    ) throws -> Data {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw R03SupportStageExecutionError.pixelBufferLockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw R03SupportStageExecutionError.missingBaseAddress
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let activeBytes = width * bytesPerPixel
        var data = Data(capacity: activeBytes * height)
        for row in 0..<height {
            data.append(
                baseAddress.assumingMemoryBound(to: UInt8.self)
                    .advanced(by: row * rowBytes),
                count: activeBytes
            )
        }
        return data
    }

    static func write(
        _ data: Data,
        to pixelBuffer: CVPixelBuffer,
        bytesPerPixel: Int
    ) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let activeBytes = width * bytesPerPixel
        guard data.count == activeBytes * height else {
            throw R03SupportStageExecutionError.invalidDimensions(
                expectedWidth: activeBytes,
                expectedHeight: height,
                actualWidth: data.count,
                actualHeight: 1
            )
        }
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw R03SupportStageExecutionError.pixelBufferLockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw R03SupportStageExecutionError.missingBaseAddress
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        data.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    baseAddress.advanced(by: row * rowBytes),
                    sourceBase.advanced(by: row * activeBytes),
                    activeBytes
                )
            }
        }
    }
}

// swiftlint:enable file_length
