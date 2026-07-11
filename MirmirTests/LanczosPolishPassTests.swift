import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Metal
import os.lock
import XCTest
@testable import Mirmir

// swiftlint:disable file_length
// swiftlint:disable type_body_length

final class LanczosPolishPassTests: XCTestCase {
    private static let contractSHA256 = "3ac96f337fca16cd36e0c4efa1f5e528e1e1f7b556820fb9dbe07ab53cb8f5ab"
    private static let maximumAbsoluteError = 1
    private static let maximumRMSE = 0.25

    func test_parityContractHashAndFixtureInventoryAreFrozen() throws {
        let data = try Data(contentsOf: parityContractURL())
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.contractSHA256)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let contractFixtureIDs = try XCTUnwrap(object["fixtures"] as? [String])
        XCTAssertEqual(contractFixtureIDs, LanczosDeterministicFixtures.all().map(\.id))
        XCTAssertEqual(object["random_seed"] as? Int, 20_260_710)
    }

    func test_cpuReferencePreservesLegalRangeConstantsExactly() throws {
        for fixture in LanczosDeterministicFixtures.all()
            where fixture.id.hasPrefix("constant_legal_") {
            let reference = try referencePlanes(for: fixture)
            XCTAssertEqual(Set(reference.luma.bytes), Set([fixture.luma[0]]))
            XCTAssertEqual(Set(reference.chroma.bytes), Set(fixture.chroma.prefix(2)))
        }
    }

    func test_deterministicFixtureInputsStayWithinDeclaredLegalRanges() {
        for fixture in LanczosDeterministicFixtures.all() {
            XCTAssertTrue(
                fixture.luma.allSatisfy { (16...235).contains($0) },
                "\(fixture.id) contains Y outside 16...235"
            )
            XCTAssertTrue(
                channel(fixture.chroma, offset: 0).allSatisfy {
                    (16...240).contains($0)
                },
                "\(fixture.id) contains Cb outside 16...240"
            )
            XCTAssertTrue(
                channel(fixture.chroma, offset: 1).allSatisfy {
                    (16...240).contains($0)
                },
                "\(fixture.id) contains Cr outside 16...240"
            )
        }
    }

    func test_pixelBufferPoolEnforcesDeclaredAllocationThreshold() throws {
        let pool = try PixelBufferBridge.makePool(width: 16, height: 16, capacity: 1)
        try autoreleasepool {
            let first = try PixelBufferBridge.dequeue(from: pool)
            XCTAssertEqual(CVPixelBufferGetWidth(first), 16)
            XCTAssertThrowsError(try PixelBufferBridge.dequeue(from: pool)) { error in
                XCTAssertEqual(
                    error as? PixelBufferBridgeError,
                    .poolDequeueFailed(kCVReturnWouldExceedAllocationThreshold)
                )
            }
        }
        let recycled = try PixelBufferBridge.dequeue(from: pool)
        XCTAssertEqual(CVPixelBufferGetHeight(recycled), 16)
    }

    func test_pixelBufferBridgeRejectsInvalidPoolAndNonNV12Buffer() throws {
        XCTAssertThrowsError(
            try PixelBufferBridge.makePool(width: 0, height: 16)
        ) { error in
            XCTAssertEqual(
                error as? PixelBufferBridgeError,
                .invalidPoolDimensions(width: 0, height: 16)
            )
        }
        XCTAssertThrowsError(
            try PixelBufferBridge.makePool(width: 16, height: 16, capacity: 0)
        ) { error in
            XCTAssertEqual(error as? PixelBufferBridgeError, .invalidPoolCapacity(0))
        }
        let bgra = try makePixelBuffer(
            width: 16,
            height: 16,
            format: kCVPixelFormatType_32BGRA
        )
        XCTAssertThrowsError(try PixelBufferBridge.validateNV12(bgra)) { error in
            XCTAssertEqual(
                error as? PixelBufferBridgeError,
                .unsupportedPixelBufferFormat(
                    expected: PixelBufferBridge.preferredFormat,
                    actual: kCVPixelFormatType_32BGRA
                )
            )
        }
    }

    func test_pixelBufferTexturesOwnBothNV12Planes() throws {
        let metal = try DefaultMetalRenderingService()
        let fixture = LanczosDeterministicFixtures.all()[0]
        let pixelBuffer = try makePixelBuffer(fixture: fixture)
        let textures = try PixelBufferBridge.makeNV12Textures(
            from: pixelBuffer,
            cache: metal.textureCache
        )

        XCTAssertTrue(textures.luma.pixelBuffer === pixelBuffer)
        XCTAssertTrue(textures.chroma.pixelBuffer === pixelBuffer)
        XCTAssertEqual(textures.luma.planeIndex, 0)
        XCTAssertEqual(textures.chroma.planeIndex, 1)
        XCTAssertEqual(textures.luma.texture.width, fixture.width)
        XCTAssertEqual(textures.chroma.texture.width, fixture.chromaWidth)
    }

    func test_completionBridgeRegistersHandlerBeforeCommit() async throws {
        let context = MetalCommandBufferExecutionContext(label: "ordering")
        let submission = RecordingMetalCommandBufferSubmission(
            context: context,
            completions: [successfulCompletion(context: context)]
        )
        let completion = try await MetalCommandBufferCompletionBridge().commitAndWait(
            submission,
            retaining: MetalCommandBufferRetainedResources([])
        )

        XCTAssertEqual(completion.status, .completed)
        XCTAssertEqual(submission.events, ["handler_registered", "commit", "callback"])
    }

    func test_completionBridgePropagatesTypedFailureWithFrameAndPTS() async throws {
        let context = MetalCommandBufferExecutionContext(
            label: "failure",
            frameIndex: 7,
            presentationTimestampValue: 100,
            presentationTimestampTimescale: 600
        )
        let completion = MetalCommandBufferCompletion(
            context: context,
            status: .error,
            error: MetalCommandBufferErrorSnapshot(
                domain: "MirmirTests.Metal",
                code: 41,
                message: "injected"
            )
        )
        let submission = RecordingMetalCommandBufferSubmission(
            context: context,
            completions: [completion]
        )

        do {
            _ = try await MetalCommandBufferCompletionBridge().commitAndWait(
                submission,
                retaining: MetalCommandBufferRetainedResources([])
            )
            XCTFail("Expected the injected command-buffer failure")
        } catch let error as MetalCommandBufferExecutionError {
            XCTAssertEqual(error, .executionFailed(completion))
            XCTAssertTrue(error.description.contains("frame 7"))
            XCTAssertTrue(error.description.contains("PTS 100/600"))
        }
    }

    func test_completionBridgeIgnoresDuplicateTerminalCallback() async throws {
        let context = MetalCommandBufferExecutionContext(label: "duplicate")
        let completion = successfulCompletion(context: context)
        let submission = RecordingMetalCommandBufferSubmission(
            context: context,
            completions: [completion, completion]
        )

        let result = try await MetalCommandBufferCompletionBridge().commitAndWait(
            submission,
            retaining: MetalCommandBufferRetainedResources([])
        )

        XCTAssertEqual(result, completion)
        XCTAssertEqual(submission.callbackCount, 2)
    }

    func test_completionBridgeRetainsResourcesUntilTerminalCallback() async throws {
        let context = MetalCommandBufferExecutionContext(label: "retention")
        let completion = successfulCompletion(context: context)
        let submission = RecordingMetalCommandBufferSubmission(
            context: context,
            completions: [completion],
            completesOnCommit: false
        )
        let deinitCount = OSAllocatedUnfairLock(initialState: 0)
        weak var weakSentinel: RetentionSentinel?
        let task: Task<MetalCommandBufferCompletion, Error>
        do {
            let sentinel = RetentionSentinel {
                deinitCount.withLock { $0 += 1 }
            }
            weakSentinel = sentinel
            let resources = MetalCommandBufferRetainedResources([sentinel])
            task = Task {
                try await MetalCommandBufferCompletionBridge().commitAndWait(
                    submission,
                    retaining: resources
                )
            }
        }
        for _ in 0..<10_000 where !submission.events.contains("commit") {
            await Task.yield()
        }
        XCTAssertNotNil(weakSentinel)
        XCTAssertEqual(deinitCount.withLock { $0 }, 0)

        submission.deliverPendingCompletions()
        _ = try await task.value
        for _ in 0..<10_000 where weakSentinel != nil {
            await Task.yield()
        }
        XCTAssertNil(weakSentinel)
        XCTAssertEqual(deinitCount.withLock { $0 }, 1)
    }

    func test_gpuLanczosMatchesFrozenCPUReferenceForBothActivePlanes() async throws {
        let metal = try DefaultMetalRenderingService()
        let pass = LanczosPolishPass(metal: metal)

        for (frameIndex, fixture) in LanczosDeterministicFixtures.all().enumerated() {
            let source = try makePixelBuffer(fixture: fixture)
            let destination = try makePixelBuffer(
                width: LanczosDeterministicFixtures.destinationWidth,
                height: LanczosDeterministicFixtures.destinationHeight
            )
            try await pass.encode(
                from: source,
                to: destination,
                frameIndex: frameIndex,
                presentationTime: CMTime(value: Int64(frameIndex), timescale: 30)
            )
            let reference = try referencePlanes(for: fixture)
            let actualLuma = readActivePlane(destination, planeIndex: 0)
            let actualChroma = readActivePlane(destination, planeIndex: 1)

            if fixture.id.hasPrefix("constant_legal_") {
                XCTAssertEqual(actualLuma, reference.luma.bytes, fixture.id)
                XCTAssertEqual(actualChroma, reference.chroma.bytes, fixture.id)
            }
            assertParity(
                expected: reference.luma.bytes,
                actual: actualLuma,
                fixtureID: fixture.id,
                plane: "Y"
            )
            assertParity(
                expected: channel(reference.chroma.bytes, offset: 0),
                actual: channel(actualChroma, offset: 0),
                fixtureID: fixture.id,
                plane: "Cb"
            )
            assertParity(
                expected: channel(reference.chroma.bytes, offset: 1),
                actual: channel(actualChroma, offset: 1),
                fixtureID: fixture.id,
                plane: "Cr"
            )
        }
    }

    func test_gpuLanczosIsByteExactAcrossSameDeviceRepeats() async throws {
        let metal = try DefaultMetalRenderingService()
        let pass = LanczosPolishPass(metal: metal)
        let fixture = try XCTUnwrap(
            LanczosDeterministicFixtures.all().first { $0.id == "fixed_seed_random" }
        )
        let source = try makePixelBuffer(fixture: fixture)
        let first = try makePixelBuffer(
            width: LanczosDeterministicFixtures.destinationWidth,
            height: LanczosDeterministicFixtures.destinationHeight
        )
        let second = try makePixelBuffer(
            width: LanczosDeterministicFixtures.destinationWidth,
            height: LanczosDeterministicFixtures.destinationHeight
        )

        try await pass.encode(from: source, to: first, frameIndex: 0, presentationTime: .zero)
        try await pass.encode(from: source, to: second, frameIndex: 0, presentationTime: .zero)

        XCTAssertEqual(readActivePlane(first, planeIndex: 0), readActivePlane(second, planeIndex: 0))
        XCTAssertEqual(readActivePlane(first, planeIndex: 1), readActivePlane(second, planeIndex: 1))
    }

    func test_lanczosRecordsCreatedCommittedAndTerminalTelemetryWithFrameAndPTS() async throws {
        let telemetry = DefaultASHTelemetryRecorder(emitsSignposts: false)
        let metal = try DefaultMetalRenderingService()
        let pass = LanczosPolishPass(metal: metal, telemetry: telemetry)
        let fixture = LanczosDeterministicFixtures.all()[0]
        let source = try makePixelBuffer(fixture: fixture)
        let destination = try makePixelBuffer(
            width: LanczosDeterministicFixtures.destinationWidth,
            height: LanczosDeterministicFixtures.destinationHeight
        )

        try await pass.encode(
            from: source,
            to: destination,
            frameIndex: 7,
            presentationTime: CMTime(value: 100, timescale: 600)
        )

        let observations = telemetry.snapshot().commandBuffers
        XCTAssertEqual(observations.map(\.status), ["created", "committed", "completed"])
        XCTAssertEqual(observations.map(\.frameIndex), [7, 7, 7])
        XCTAssertEqual(observations.map(\.presentationTimestampValue), [100, 100, 100])
        XCTAssertEqual(observations.map(\.presentationTimestampTimescale), [600, 600, 600])
        let terminal = try XCTUnwrap(observations.last)
        XCTAssertNotNil(terminal.gpuStartSeconds)
        XCTAssertNotNil(terminal.gpuEndSeconds)
    }

    private func parityContractURL(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/lanczos-parity-v1.json")
    }

    private func referencePlanes(
        for fixture: LanczosNV12Fixture
    ) throws -> (luma: LanczosReferencePlane, chroma: LanczosReferencePlane) {
        let luma = try LanczosReferencePlane(
            width: fixture.width,
            height: fixture.height,
            channels: 1,
            bytes: fixture.luma
        )
        let chroma = try LanczosReferencePlane(
            width: fixture.chromaWidth,
            height: fixture.chromaHeight,
            channels: 2,
            bytes: fixture.chroma
        )
        return (
            try LanczosCPUReference.scale(
                luma,
                destinationWidth: LanczosDeterministicFixtures.destinationWidth,
                destinationHeight: LanczosDeterministicFixtures.destinationHeight
            ),
            try LanczosCPUReference.scale(
                chroma,
                destinationWidth: LanczosDeterministicFixtures.destinationWidth / 2,
                destinationHeight: LanczosDeterministicFixtures.destinationHeight / 2
            )
        )
    }

    private func assertParity(
        expected: [UInt8],
        actual: [UInt8],
        fixtureID: String,
        plane: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(expected.count, actual.count, file: file, line: line)
        guard expected.count == actual.count else { return }
        let metrics = ByteErrorMetrics(expected: expected, actual: actual)
        XCTAssertLessThanOrEqual(
            metrics.maximumAbsoluteError,
            Self.maximumAbsoluteError,
            "\(fixtureID) \(plane) max absolute error \(metrics.maximumAbsoluteError)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            metrics.rmse,
            Self.maximumRMSE,
            "\(fixtureID) \(plane) RMSE \(metrics.rmse)",
            file: file,
            line: line
        )
    }

    private func channel(_ bytes: [UInt8], offset: Int) -> [UInt8] {
        stride(from: offset, to: bytes.count, by: 2).map { bytes[$0] }
    }

    private func makePixelBuffer(fixture: LanczosNV12Fixture) throws -> CVPixelBuffer {
        let pixelBuffer = try makePixelBuffer(width: fixture.width, height: fixture.height)
        writeActivePlane(fixture.luma, to: pixelBuffer, planeIndex: 0)
        writeActivePlane(fixture.chroma, to: pixelBuffer, planeIndex: 1)
        return pixelBuffer
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        format: OSType = PixelBufferBridge.preferredFormat
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw PixelBufferBridgeError.poolCreationFailed(status)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if CVPixelBufferGetPlaneCount(pixelBuffer) > 0 {
            for planeIndex in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
                if let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex) {
                    memset(
                        baseAddress,
                        0,
                        CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex)
                            * CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
                    )
                }
            }
        } else if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private func writeActivePlane(
        _ bytes: [UInt8],
        to pixelBuffer: CVPixelBuffer,
        planeIndex: Int
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex) else {
            return XCTFail("Missing plane \(planeIndex)")
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        let bytesPerPixel = planeIndex == 0 ? 1 : 2
        let activeBytesPerRow = width * bytesPerPixel
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex)
        XCTAssertEqual(bytes.count, activeBytesPerRow * height)
        bytes.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    baseAddress.advanced(by: row * rowBytes),
                    sourceBase.advanced(by: row * activeBytesPerRow),
                    activeBytesPerRow
                )
            }
        }
    }

    private func readActivePlane(
        _ pixelBuffer: CVPixelBuffer,
        planeIndex: Int
    ) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex) else {
            XCTFail("Missing plane \(planeIndex)")
            return []
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        let bytesPerPixel = planeIndex == 0 ? 1 : 2
        let activeBytesPerRow = width * bytesPerPixel
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(activeBytesPerRow * height)
        for row in 0..<height {
            let rowStart = baseAddress.advanced(by: row * rowBytes)
                .assumingMemoryBound(to: UInt8.self)
            bytes.append(contentsOf: UnsafeBufferPointer(
                start: rowStart,
                count: activeBytesPerRow
            ))
        }
        return bytes
    }

    private func successfulCompletion(
        context: MetalCommandBufferExecutionContext
    ) -> MetalCommandBufferCompletion {
        MetalCommandBufferCompletion(context: context, status: .completed)
    }
}

// swiftlint:enable type_body_length

private struct ByteErrorMetrics {
    let maximumAbsoluteError: Int
    let rmse: Double

    init(expected: [UInt8], actual: [UInt8]) {
        var maximumAbsoluteError = 0
        var squaredError = 0.0
        for (expectedValue, actualValue) in zip(expected, actual) {
            let difference = abs(Int(expectedValue) - Int(actualValue))
            maximumAbsoluteError = max(maximumAbsoluteError, difference)
            squaredError += Double(difference * difference)
        }
        self.maximumAbsoluteError = maximumAbsoluteError
        self.rmse = expected.isEmpty ? 0 : sqrt(squaredError / Double(expected.count))
    }
}

private final class RecordingMetalCommandBufferSubmission:
    MetalCommandBufferSubmitting,
    @unchecked Sendable {
    private struct State {
        var events: [String] = []
        var handler: (@Sendable (MetalCommandBufferCompletion) -> Void)?
        var callbackCount = 0
    }

    let context: MetalCommandBufferExecutionContext
    private let completions: [MetalCommandBufferCompletion]
    private let completesOnCommit: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        context: MetalCommandBufferExecutionContext,
        completions: [MetalCommandBufferCompletion],
        completesOnCommit: Bool = true
    ) {
        self.context = context
        self.completions = completions
        self.completesOnCommit = completesOnCommit
    }

    var events: [String] { state.withLock { $0.events } }
    var callbackCount: Int { state.withLock { $0.callbackCount } }

    func addCompletedHandler(
        _ handler: @escaping @Sendable (MetalCommandBufferCompletion) -> Void
    ) {
        state.withLock { state in
            state.events.append("handler_registered")
            state.handler = handler
        }
    }

    func commit() {
        state.withLock { $0.events.append("commit") }
        if completesOnCommit {
            deliverPendingCompletions()
        }
    }

    func deliverPendingCompletions() {
        let handler = state.withLock { state -> (@Sendable (
            MetalCommandBufferCompletion
        ) -> Void)? in
            defer { state.handler = nil }
            return state.handler
        }
        guard let handler else { return }
        for completion in completions {
            state.withLock { state in
                state.callbackCount += 1
                state.events.append("callback")
            }
            handler(completion)
        }
    }
}

private final class RetentionSentinel {
    private let onDeinit: () -> Void

    init(onDeinit: @escaping () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

// swiftlint:enable file_length
