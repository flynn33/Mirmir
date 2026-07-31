import Foundation
@preconcurrency import Metal
import XCTest
@testable import Mirmir

// The doubles intentionally cover every asynchronous terminal path in one file.
// swiftlint:disable file_length

final class R05MetalFXSpatialDriverTests: XCTestCase {
    func testBothRoutesConfigureLinearRGBA16FloatAndOrderedPipeline() async throws {
        for route in R05MetalFXSpatialDriverRoute.allCases {
            let harness = R05SpatialHarness()
            let publishCount = R05SpatialCounter()
            let extraResource = R05SpatialResource()
            let outcome = await harness.driver.process(
                request(
                    route: route,
                    retainedResources: [extraResource],
                    publish: {
                        harness.recorder.append("publish")
                        publishCount.increment()
                    }
                )
            )

            guard case .processed(let processed) = outcome else {
                return XCTFail("Expected route \(route.rawValue) to process")
            }
            XCTAssertEqual(processed.route, route)
            XCTAssertEqual(processed.destination.dimensions, route.targetDimensions)
            XCTAssertEqual(publishCount.value, 1)

            XCTAssertEqual(
                harness.factory.configurations,
                [
                    R05MetalFXSpatialScalerConfiguration(
                        inputDimensions: route.sourceDimensions,
                        outputDimensions: route.targetDimensions,
                        colorTextureFormat: .rgba16Float,
                        outputTextureFormat: .rgba16Float,
                        colorMode: .linear
                    )
                ]
            )
            let descriptors = harness.allocator.descriptors
            XCTAssertEqual(descriptors.count, 2)
            XCTAssertEqual(descriptors[0].dimensions, route.sourceDimensions)
            XCTAssertEqual(descriptors[0].pixelFormat, .rgba16Float)
            XCTAssertEqual(descriptors[0].storageMode, .private)
            assertUsage(
                descriptors[0].usage,
                contains: harness.scaler.colorTextureUsage.union(.shaderWrite)
            )
            XCTAssertEqual(descriptors[1].dimensions, route.targetDimensions)
            XCTAssertEqual(descriptors[1].pixelFormat, .rgba16Float)
            XCTAssertEqual(descriptors[1].storageMode, .private)
            assertUsage(
                descriptors[1].usage,
                contains: harness.scaler.outputTextureUsage.union(.shaderRead)
            )
            XCTAssertEqual(harness.scaler.inputContentDimensions, [route.sourceDimensions])
            XCTAssertEqual(
                harness.recorder.events,
                [
                    "supports",
                    "make-scaler",
                    "allocate-input",
                    "allocate-output",
                    "make-command-buffer",
                    "decode-upload",
                    "scale",
                    "encode-readback",
                    "commit",
                    "complete",
                    "finalize",
                    "publish"
                ]
            )
            XCTAssertEqual(harness.completer.retainedCounts, [9])
            XCTAssertTrue(
                harness.completer.retainedObjectIdentifiers[0].contains(
                    ObjectIdentifier(extraResource)
                )
            )
        }
    }

    func testDeviceSupportGuardPrecedesDescriptorFactoryAndEncoding() async {
        let harness = R05SpatialHarness(supported: false)

        let outcome = await harness.driver.process(request(route: .two))

        assertUnsupported(outcome, .deviceUnsupported)
        XCTAssertEqual(harness.recorder.events, ["supports"])
        XCTAssertEqual(harness.factory.configurations, [])
        XCTAssertEqual(harness.allocator.descriptors, [])
    }

    func testNilScalerFactoryIsTypedUnavailableWithoutSilentFallback() async {
        let harness = R05SpatialHarness(scalerFactoryReturnsNil: true)

        let outcome = await harness.driver.process(request(route: .oneAndOneHalf))

        assertUnavailable(outcome, .spatialScalerCreationReturnedNil)
        XCTAssertEqual(harness.recorder.events, ["supports", "make-scaler"])
        XCTAssertEqual(harness.allocator.descriptors, [])
    }

    func testGeometryMismatchRejectsBeforeSupportQuery() async {
        let harness = R05SpatialHarness()
        let source = R05SpatialSurface(
            dimensions: R05MetalFXSpatialDriverDimensions(width: 12, height: 8)
        )
        let request = R05MetalFXSpatialDriverRequest(
            route: .two,
            source: source,
            destination: R05SpatialSurface(dimensions: .init(width: 3840, height: 2160)),
            publish: {}
        )

        let outcome = await harness.driver.process(request)

        guard case .rejected(.sourceGeometryMismatch) = outcome else {
            return XCTFail("Expected a typed source-geometry rejection")
        }
        XCTAssertEqual(harness.recorder.events, [])
    }

    func testCommandFailureDoesNotFinalizeOrPublish() async {
        let harness = R05SpatialHarness(completionMode: .immediateFailure)
        let publishCount = R05SpatialCounter()

        let outcome = await harness.driver.process(
            request(route: .two, publish: { publishCount.increment() })
        )

        assertFailed(outcome, .commandExecutionFailed)
        XCTAssertEqual(publishCount.value, 0)
        XCTAssertFalse(harness.recorder.events.contains("finalize"))
        XCTAssertFalse(harness.recorder.events.contains("publish"))
    }

    func testPostCommitCancellationSuppressesFinalizationAndPublication() async {
        let harness = R05SpatialHarness(completionMode: .manual)
        let cancellation = R05SpatialCancellationProbe()
        let publishCount = R05SpatialCounter()
        let extraResource = R05SpatialResource()
        let processRequest = request(
            route: .two,
            retainedResources: [extraResource],
            cancellation: cancellation.contract,
            publish: { publishCount.increment() }
        )
        let task = Task {
            await harness.driver.process(processRequest)
        }
        let reachedCommit = await waitUntil { harness.completer.pendingCount == 1 }
        XCTAssertTrue(reachedCommit)
        XCTAssertEqual(harness.completer.retainedCounts, [9])
        XCTAssertTrue(
            harness.completer.retainedObjectIdentifiers[0].contains(
                ObjectIdentifier(extraResource)
            )
        )

        cancellation.cancel()
        harness.completer.completeNext(.success(()))
        let outcome = await task.value

        assertCancelled(outcome, .afterCommit)
        XCTAssertFalse(harness.recorder.events.contains("finalize"))
        XCTAssertEqual(publishCount.value, 0)
    }

    func testPrecommitCancellationDoesNotQuerySupportOrPublish() async {
        let harness = R05SpatialHarness()
        let cancellation = R05SpatialCancellationProbe(cancelled: true)
        let publishCount = R05SpatialCounter()

        let outcome = await harness.driver.process(
            request(
                route: .two,
                cancellation: cancellation.contract,
                publish: { publishCount.increment() }
            )
        )

        assertCancelled(outcome, .beforeCommit)
        XCTAssertEqual(harness.recorder.events, [])
        XCTAssertEqual(publishCount.value, 0)
    }

    func testFinalizationFailureIsTypedAndPublicationIsSuppressed() async {
        let harness = R05SpatialHarness(finalizationFails: true)
        let publishCount = R05SpatialCounter()

        let outcome = await harness.driver.process(
            request(route: .oneAndOneHalf, publish: { publishCount.increment() })
        )

        assertFailed(outcome, .outputFinalizationFailed)
        XCTAssertEqual(publishCount.value, 0)
        XCTAssertEqual(
            Array(harness.recorder.events.suffix(3)),
            ["commit", "complete", "finalize"]
        )
    }

    func testMutableScalerUseRemainsSerializedAcrossCommandCompletion() async {
        let harness = R05SpatialHarness(completionMode: .manual)
        let firstRequest = request(route: .oneAndOneHalf)
        let first = Task {
            await harness.driver.process(firstRequest)
        }
        let firstReachedCommit = await waitUntil { harness.completer.pendingCount == 1 }
        XCTAssertTrue(firstReachedCommit)

        let secondRequest = request(route: .two)
        let second = Task {
            await harness.driver.process(secondRequest)
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(harness.factory.configurations.count, 1)

        harness.completer.completeNext(.success(()))
        let secondStarted = await waitUntil { harness.factory.configurations.count == 2 }
        XCTAssertTrue(secondStarted)
        let secondReachedCommit = await waitUntil { harness.completer.pendingCount == 1 }
        XCTAssertTrue(secondReachedCommit)
        harness.completer.completeNext(.success(()))

        guard case .processed = await first.value else {
            return XCTFail("Expected first serialized request to process")
        }
        guard case .processed = await second.value else {
            return XCTFail("Expected second serialized request to process")
        }
        XCTAssertEqual(harness.scaler.peakConcurrentEncodes, 1)
    }

    private func request(
        route: R05MetalFXSpatialDriverRoute,
        retainedResources: [AnyObject] = [],
        cancellation: R05MetalFXSpatialDriverCancellation = .never,
        publish: @escaping @Sendable () throws -> Void = {}
    ) -> R05MetalFXSpatialDriverRequest {
        R05MetalFXSpatialDriverRequest(
            route: route,
            source: R05SpatialSurface(dimensions: route.sourceDimensions),
            destination: R05SpatialSurface(dimensions: route.targetDimensions),
            retainedResources: retainedResources,
            cancellation: cancellation,
            publish: publish
        )
    }

    private func waitUntil(
        _ predicate: () -> Bool
    ) async -> Bool {
        for _ in 0..<2_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return false
    }

    private func assertUsage(
        _ observed: MTLTextureUsage,
        contains expected: MTLTextureUsage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            observed.intersection(expected),
            expected,
            file: file,
            line: line
        )
    }

    private func assertUnsupported(
        _ outcome: R05MetalFXSpatialDriverOutcome,
        _ expected: R05MetalFXSpatialDriverUnsupportedReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unsupported(let reason) = outcome else {
            return XCTFail("Expected unsupported outcome", file: file, line: line)
        }
        XCTAssertEqual(reason, expected, file: file, line: line)
    }

    private func assertUnavailable(
        _ outcome: R05MetalFXSpatialDriverOutcome,
        _ expected: R05MetalFXSpatialDriverUnavailableReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("Expected unavailable outcome", file: file, line: line)
        }
        XCTAssertEqual(reason, expected, file: file, line: line)
    }

    private func assertFailed(
        _ outcome: R05MetalFXSpatialDriverOutcome,
        _ expected: R05MetalFXSpatialDriverFailureReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failed(let reason) = outcome else {
            return XCTFail("Expected failed outcome", file: file, line: line)
        }
        XCTAssertEqual(reason, expected, file: file, line: line)
    }

    private func assertCancelled(
        _ outcome: R05MetalFXSpatialDriverOutcome,
        _ expected: R05MetalFXSpatialCancellationReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .cancelled(let reason) = outcome else {
            return XCTFail("Expected cancelled outcome", file: file, line: line)
        }
        XCTAssertEqual(reason, expected, file: file, line: line)
    }
}

private enum R05SpatialTestError: Error {
    case injected
}

private final class R05SpatialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.withLock { storage }
    }

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }
}

private final class R05SpatialCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class R05SpatialCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(cancelled: Bool = false) {
        storage = cancelled
    }

    var contract: R05MetalFXSpatialDriverCancellation {
        R05MetalFXSpatialDriverCancellation(
            isCancelled: { [weak self] in self?.isCancelled ?? true }
        )
    }

    func cancel() {
        lock.withLock { storage = true }
    }

    private var isCancelled: Bool { lock.withLock { storage } }
}

private final class R05SpatialResource: @unchecked Sendable {}

private final class R05SpatialSurface: R05MetalFXSpatialNV12Surface,
    @unchecked Sendable {
    let dimensions: R05MetalFXSpatialDriverDimensions

    init(dimensions: R05MetalFXSpatialDriverDimensions) {
        self.dimensions = dimensions
    }
}

private final class R05SpatialTexture: R05MetalFXSpatialTexture,
    @unchecked Sendable {
    let descriptor: R05MetalFXSpatialTextureDescriptor

    init(descriptor: R05MetalFXSpatialTextureDescriptor) {
        self.descriptor = descriptor
    }
}

private final class R05SpatialCommandBuffer: R05MetalFXSpatialCommandBuffer,
    @unchecked Sendable {}

private final class R05SpatialScaler: R05MetalFXSpatialScaler,
    @unchecked Sendable {
    let colorTextureUsage: MTLTextureUsage = [.shaderRead, .pixelFormatView]
    let outputTextureUsage: MTLTextureUsage = [.shaderWrite, .renderTarget]

    private let recorder: R05SpatialRecorder
    private let fails: Bool
    private let lock = NSLock()
    private var dimensionsStorage: [R05MetalFXSpatialDriverDimensions] = []
    private var concurrentEncodes = 0
    private var peakStorage = 0

    init(recorder: R05SpatialRecorder, fails: Bool = false) {
        self.recorder = recorder
        self.fails = fails
    }

    var inputContentDimensions: [R05MetalFXSpatialDriverDimensions] {
        lock.withLock { dimensionsStorage }
    }

    var peakConcurrentEncodes: Int { lock.withLock { peakStorage } }

    func encode(
        colorTexture _: any R05MetalFXSpatialTexture,
        outputTexture _: any R05MetalFXSpatialTexture,
        inputContentDimensions: R05MetalFXSpatialDriverDimensions,
        commandBuffer _: any R05MetalFXSpatialCommandBuffer
    ) throws {
        lock.withLock {
            concurrentEncodes += 1
            peakStorage = max(peakStorage, concurrentEncodes)
            dimensionsStorage.append(inputContentDimensions)
        }
        defer { lock.withLock { concurrentEncodes -= 1 } }
        recorder.append("scale")
        if fails { throw R05SpatialTestError.injected }
    }
}

private final class R05SpatialScalerFactory: R05MetalFXSpatialScalerCreating,
    @unchecked Sendable {
    private let recorder: R05SpatialRecorder
    private let supported: Bool
    private let returnsNil: Bool
    private let scaler: R05SpatialScaler
    private let lock = NSLock()
    private var configurationStorage: [R05MetalFXSpatialScalerConfiguration] = []

    init(
        recorder: R05SpatialRecorder,
        supported: Bool,
        returnsNil: Bool,
        scaler: R05SpatialScaler
    ) {
        self.recorder = recorder
        self.supported = supported
        self.returnsNil = returnsNil
        self.scaler = scaler
    }

    var configurations: [R05MetalFXSpatialScalerConfiguration] {
        lock.withLock { configurationStorage }
    }

    func supportsDevice() -> Bool {
        recorder.append("supports")
        return supported
    }

    func makeScaler(
        configuration: R05MetalFXSpatialScalerConfiguration
    ) -> (any R05MetalFXSpatialScaler)? {
        recorder.append("make-scaler")
        lock.withLock { configurationStorage.append(configuration) }
        return returnsNil ? nil : scaler
    }
}

private final class R05SpatialTextureAllocator: R05MetalFXSpatialTextureAllocating,
    @unchecked Sendable {
    private let recorder: R05SpatialRecorder
    private let lock = NSLock()
    private var descriptorStorage: [R05MetalFXSpatialTextureDescriptor] = []

    init(recorder: R05SpatialRecorder) {
        self.recorder = recorder
    }

    var descriptors: [R05MetalFXSpatialTextureDescriptor] {
        lock.withLock { descriptorStorage }
    }

    func makeTexture(
        descriptor: R05MetalFXSpatialTextureDescriptor
    ) -> (any R05MetalFXSpatialTexture)? {
        let ordinal = lock.withLock { () -> Int in
            descriptorStorage.append(descriptor)
            return descriptorStorage.count
        }
        recorder.append(ordinal == 1 ? "allocate-input" : "allocate-output")
        return R05SpatialTexture(descriptor: descriptor)
    }
}

private final class R05SpatialCommandBufferFactory:
    R05MetalFXSpatialCommandBufferCreating, @unchecked Sendable {
    private let recorder: R05SpatialRecorder

    init(recorder: R05SpatialRecorder) {
        self.recorder = recorder
    }

    func makeCommandBuffer(
        label _: String
    ) -> (any R05MetalFXSpatialCommandBuffer)? {
        recorder.append("make-command-buffer")
        return R05SpatialCommandBuffer()
    }
}

private final class R05SpatialColorConverter: R05MetalFXSpatialColorConverting,
    @unchecked Sendable {
    private let recorder: R05SpatialRecorder
    private let finalizationFails: Bool
    private let decodeResource = R05SpatialResource()
    private let encodeResource = R05SpatialResource()

    init(recorder: R05SpatialRecorder, finalizationFails: Bool) {
        self.recorder = recorder
        self.finalizationFails = finalizationFails
    }

    func encodeNV12ToLinear(
        source _: any R05MetalFXSpatialNV12Surface,
        destination _: any R05MetalFXSpatialTexture,
        commandBuffer _: any R05MetalFXSpatialCommandBuffer
    ) throws -> [AnyObject] {
        recorder.append("decode-upload")
        return [decodeResource]
    }

    func encodeLinearToNV12(
        source _: any R05MetalFXSpatialTexture,
        destination _: any R05MetalFXSpatialNV12Surface,
        commandBuffer _: any R05MetalFXSpatialCommandBuffer
    ) throws -> R05MetalFXSpatialPendingOutputConversion {
        recorder.append("encode-readback")
        return R05MetalFXSpatialPendingOutputConversion(
            retainedResources: [encodeResource],
            finalize: { [recorder, finalizationFails] in
                recorder.append("finalize")
                if finalizationFails { throw R05SpatialTestError.injected }
            }
        )
    }
}

private enum R05SpatialCompletionMode {
    case immediateSuccess
    case immediateFailure
    case manual
}

private final class R05SpatialCommandCompleter: R05MetalFXSpatialCommandCompleting,
    @unchecked Sendable {
    private struct State {
        var continuations: [CheckedContinuation<Void, Error>] = []
        var retainedCounts: [Int] = []
        var retainedObjectIdentifiers: [Set<ObjectIdentifier>] = []
    }

    private let recorder: R05SpatialRecorder
    private let mode: R05SpatialCompletionMode
    private let lock = NSLock()
    private var state = State()

    init(recorder: R05SpatialRecorder, mode: R05SpatialCompletionMode) {
        self.recorder = recorder
        self.mode = mode
    }

    var pendingCount: Int { lock.withLock { state.continuations.count } }
    var retainedCounts: [Int] { lock.withLock { state.retainedCounts } }
    var retainedObjectIdentifiers: [Set<ObjectIdentifier>] {
        lock.withLock { state.retainedObjectIdentifiers }
    }

    func commitAndWait(
        commandBuffer _: any R05MetalFXSpatialCommandBuffer,
        retaining resources: R05MetalFXSpatialRetainedResources
    ) async throws {
        recorder.append("commit")
        lock.withLock {
            state.retainedCounts.append(resources.count)
            state.retainedObjectIdentifiers.append(
                Set(resources.objects.map(ObjectIdentifier.init))
            )
        }
        switch mode {
        case .immediateSuccess:
            recorder.append("complete")
        case .immediateFailure:
            throw R05SpatialTestError.injected
        case .manual:
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { state.continuations.append(continuation) }
            }
            recorder.append("complete")
        }
    }

    func completeNext(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { state.continuations.removeFirst() }
        continuation.resume(with: result)
    }
}

private final class R05SpatialHarness: @unchecked Sendable {
    let recorder: R05SpatialRecorder
    let scaler: R05SpatialScaler
    let factory: R05SpatialScalerFactory
    let allocator: R05SpatialTextureAllocator
    let completer: R05SpatialCommandCompleter
    let driver: R05MetalFXSpatialDriver

    init(
        supported: Bool = true,
        scalerFactoryReturnsNil: Bool = false,
        scalerFails: Bool = false,
        finalizationFails: Bool = false,
        completionMode: R05SpatialCompletionMode = .immediateSuccess
    ) {
        let recorder = R05SpatialRecorder()
        let scaler = R05SpatialScaler(recorder: recorder, fails: scalerFails)
        let factory = R05SpatialScalerFactory(
            recorder: recorder,
            supported: supported,
            returnsNil: scalerFactoryReturnsNil,
            scaler: scaler
        )
        let allocator = R05SpatialTextureAllocator(recorder: recorder)
        let completer = R05SpatialCommandCompleter(
            recorder: recorder,
            mode: completionMode
        )
        self.recorder = recorder
        self.scaler = scaler
        self.factory = factory
        self.allocator = allocator
        self.completer = completer
        self.driver = R05MetalFXSpatialDriver(
            scalerFactory: factory,
            textureAllocator: allocator,
            commandBufferFactory: R05SpatialCommandBufferFactory(recorder: recorder),
            colorConverter: R05SpatialColorConverter(
                recorder: recorder,
                finalizationFails: finalizationFails
            ),
            commandCompleter: completer
        )
    }
}
