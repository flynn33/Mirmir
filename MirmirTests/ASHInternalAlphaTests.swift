import CoreVideo
import CryptoKit
import Metal
@testable import Mirmir
import XCTest

// The backend byte-identity fixture shares the established NV12 test helpers.
// swiftlint:disable type_body_length
final class ASHInternalAlphaTests: XCTestCase {
    func test_startupValidatorLoadsASHAssetsFromBuiltApplicationBundle() {
        let applicationBundle = Bundle(for: AVFoundationMediaPipeline.self)

        XCTAssertEqual(
            ASHBackendStartupValidator.validate(bundle: applicationBundle),
            .available
        )
    }

    func test_runtimeConformanceReportValidatesAllBundledASHAssets() throws {
        let catalog = try ASHAssetCatalog.load(from: ashAssetRootURL())
        let report = try catalog.validateRuntime()

        XCTAssertTrue(report.isValid)
        XCTAssertEqual(report.validatedCodewordCount, 16)
        XCTAssertEqual(report.validatedStateCount, 512)
        XCTAssertEqual(report.validatedBranchLeafCount, 81)
        XCTAssertEqual(report.validatedFeatureCoordinateCount, 9)
        XCTAssertTrue(report.certificateChecksPassed)
    }

    func test_runtimeConformanceRejectsMutatedMappingThreshold() throws {
        var catalog = try ASHAssetCatalog.load(from: ashAssetRootURL())
        catalog.mapping.coordinates[0].threshold = (catalog.mapping.coordinates[0].threshold ?? 0.0) + 0.125

        let report = try catalog.validateRuntime()

        XCTAssertFalse(report.isValid)
        XCTAssertFalse(report.mappingMatchesRuntime)
    }

    func test_tileProcessorSelectsMultipleMessagesForStructuredFrame() throws {
        let image = try ASHImage(grayscaleRows: [
            stridePattern(width: 64, low: 0.05, high: 0.85),
            stridePattern(width: 64, low: 0.05, high: 0.85),
            rampPattern(width: 64)
        ], repeatRowsToHeight: 32)
        let processor = ASHTileProcessor(tileSize: 32, scale: 2, topK: 4)

        let result = try processor.process(luma: image)

        XCTAssertEqual(result.summary.tileCount, 2)
        XCTAssertGreaterThan(Set(result.decisions.map(\.selectedMessage.rawValue)).count, 1)
        XCTAssertGreaterThan(result.summary.estimatedPeakTemporaryBytes, 0)
        XCTAssertEqual(result.summary.maxCandidatesPerTile, 16)
    }

    func test_nv12ChromaEnergyChangesFeatureVector() throws {
        let luma = try ASHImage(width: 8, height: 8) { row, col in
            Double((row + col) % 2)
        }
        let neutral = ASHChromaPlane(
            width: 4,
            height: 4,
            bytesPerRow: 8,
            bytes: Array(repeating: 128, count: 32)
        )
        let saturated = ASHChromaPlane(
            width: 4,
            height: 4,
            bytesPerRow: 8,
            bytes: Array(repeating: 96, count: 32).enumerated().map { index, value in
                index.isMultiple(of: 2) ? 48 : value
            }
        )

        let neutralFeatures = try ASHFeatureExtractor.extract(
            current: luma,
            chromaEnergy: neutral.energy(inLumaRect: ASHIntRect(originX: 0, originY: 0, width: 8, height: 8))
        )
        let saturatedFeatures = try ASHFeatureExtractor.extract(
            current: luma,
            chromaEnergy: saturated.energy(inLumaRect: ASHIntRect(originX: 0, originY: 0, width: 8, height: 8))
        )

        XCTAssertEqual(neutralFeatures.values[4], 0, accuracy: 1e-12)
        XCTAssertGreaterThan(saturatedFeatures.values[4], neutralFeatures.values[4])
    }

    func test_branchFixtureSuiteSelectsAtLeastFourNonNeutralMessages() throws {
        let processor = ASHTileProcessor(tileSize: 32, scale: 2, topK: 4)
        let fixtures = try branchEvidenceFixtures()
        let selected = try fixtures.flatMap { fixture in
            try processor.process(luma: fixture).decisions.map(\.selectedMessage)
        }
        let nonNeutralMessages = Set(selected.filter { $0.rawValue != 0 }.map(\.rawValue))

        XCTAssertGreaterThanOrEqual(
            nonNeutralMessages.count,
            4,
            "selected messages: \(selected.map(\.rawValue).sorted())"
        )
    }

    func test_metalLumaOperatorMatchesCPUReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable in this environment")
        }
        let source = try ASHImage(width: 8, height: 8) { row, col in
            Double((row * 17 + col * 11) % 255) / 255.0
        }
        let message = try ASHMessage(rawValue: 0b1011)

        let cpu = try ASHLumaSpatialOperator.applyCPU(
            source: source,
            message: message,
            scale: 2,
            strength: 0.22
        )
        let metal = try ASHMetalLumaSpatialOperator(device: device).apply(
            source: source,
            message: message,
            scale: 2,
            strength: 0.22
        )

        XCTAssertEqual(cpu.width, metal.width)
        XCTAssertEqual(cpu.height, metal.height)
        for index in cpu.values.indices {
            XCTAssertEqual(cpu.values[index], metal.values[index], accuracy: 1.0 / 255.0 + 1e-6)
        }
    }

    func test_backendProcessesNV12BufferAndWritesDeterministicOutput() async throws {
        let source = try makeNV12PixelBuffer(width: 16, height: 8) { row, col in
            UInt8((row * 9 + col * 5) % 255)
        } chroma: { row, col in
            (UInt8(80 + (row + col) % 24), UInt8(176 - (row * 3 + col) % 24))
        }
        let firstDestination = try makeNV12PixelBuffer(width: 32, height: 16)
        let secondDestination = try makeNV12PixelBuffer(width: 32, height: 16)

        let firstBackend = ASHDeterministicUpscaleBackend(route: .direct2x)
        try await firstBackend.process(source: source, into: firstDestination)

        let secondBackend = ASHDeterministicUpscaleBackend(route: .direct2x)
        try await secondBackend.process(source: source, into: secondDestination)

        XCTAssertEqual(readPlane(firstDestination, plane: 0), readPlane(secondDestination, plane: 0))
        XCTAssertEqual(readPlane(firstDestination, plane: 1), readPlane(secondDestination, plane: 1))
        XCTAssertGreaterThan(Set(readPlane(firstDestination, plane: 0)).count, 8)
        XCTAssertGreaterThan(Set(readPlane(firstDestination, plane: 1)).count, 2)
    }

    func test_backendMatchesPreCodecExtractionByteIdentityFixture() async throws {
        let source = try makeNV12PixelBuffer(width: 16, height: 8) { row, col in
            UInt8((row * 9 + col * 5) % 255)
        } chroma: { row, col in
            (UInt8(80 + (row + col) % 24), UInt8(176 - (row * 3 + col) % 24))
        }
        let destination = try makeNV12PixelBuffer(width: 32, height: 16)

        try await ASHDeterministicUpscaleBackend(route: .direct2x).process(
            source: source,
            into: destination
        )

        let lumaHash = SHA256.hash(data: Data(readPlane(destination, plane: 0)))
        let chromaHash = SHA256.hash(data: Data(readPlane(destination, plane: 1)))
        let lumaHex = lumaHash.map { String(format: "%02x", $0) }.joined()
        let chromaHex = chromaHash.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            lumaHex,
            "730583684098628c0f0023793e473481d2400b1de9300f31b32f33890d366222"
        )
        XCTAssertEqual(
            chromaHex,
            "0df5a01b69bcb42582395ac8b0f813383eeac0310af74d2d56b7d8fba1cc0704"
        )
    }

    func test_backendRunsDirect3Over2WithLegalDirectChromaOutput() async throws {
        let lumaGenerator: (Int, Int) -> UInt8 = { row, col in
            UInt8(16 + ((row * 17 + col * 11) % 220))
        }
        let chromaGenerator: (Int, Int) -> (UInt8, UInt8) = { row, col in
            (
                UInt8(16 + ((row * 23 + col * 31) % 225)),
                UInt8(240 - ((row * 29 + col * 19) % 225))
            )
        }
        let source = try makeNV12PixelBuffer(
            width: 16,
            height: 8,
            luma: lumaGenerator,
            chroma: chromaGenerator
        )
        let destination = try makeNV12PixelBuffer(width: 24, height: 12)
        let backend = ASHDeterministicUpscaleBackend(route: .direct3Over2)

        try await backend.process(source: source, into: destination)
        let luma = readPlane(destination, plane: 0)
        let chroma = readPlane(destination, plane: 1)
        let summary = try XCTUnwrap(backend.lastDebugSummary)

        XCTAssertEqual(summary.route, .direct3Over2)
        XCTAssertEqual(summary.reconstructedLumaSampleCount, 24 * 12)
        XCTAssertEqual(summary.reconstructedChromaSampleCount, 2 * 12 * 6)
        XCTAssertTrue(luma.allSatisfy { (16...235).contains($0) })
        XCTAssertTrue(chroma.allSatisfy { (16...240).contains($0) })
        XCTAssertGreaterThan(Set(luma).count, 8)
        XCTAssertGreaterThan(Set(chroma).count, 4)
        XCTAssertEqual(summary.runtimeTreeGenerationCount, 0)
        XCTAssertFalse(summary.nearestExpansionUsed)
    }

    func test_backendDebugSummaryReportsDirectStateConditionedPlanes() async throws {
        let source = try makeNV12PixelBuffer(width: 16, height: 8) { row, col in
            if col < 8 {
                return UInt8(row < 4 ? 28 : 228)
            }
            return UInt8((row + col).isMultiple(of: 2) ? 236 : 20)
        } chroma: { _, _ in
            (64, 192)
        }
        let destination = try makeNV12PixelBuffer(width: 32, height: 16)
        let backend = ASHDeterministicUpscaleBackend(route: .direct2x)

        try await backend.process(source: source, into: destination)
        let summary = try XCTUnwrap(backend.lastDebugSummary)

        XCTAssertEqual(summary.analysisSampleCount, 16 * 8)
        XCTAssertEqual(summary.reconstructedLumaSampleCount, 32 * 16)
        XCTAssertEqual(summary.reconstructedChromaSampleCount, 2 * 16 * 8)
        XCTAssertGreaterThan(summary.stateHistogram.count, 1)
        XCTAssertGreaterThan(summary.operatorHistogram.count, 1)
        XCTAssertLessThanOrEqual(summary.maxOperatorEvaluations, 2)
        XCTAssertEqual(summary.temporalStateCount, 0)
        XCTAssertEqual(summary.runtimeTreeGenerationCount, 0)
        XCTAssertFalse(summary.nearestExpansionUsed)
    }

    func test_backendUsesAndPropagatesProgressiveChromaSiting() async throws {
        let luma: (Int, Int) -> UInt8 = { _, column in column < 8 ? 32 : 220 }
        let chroma: (Int, Int) -> (UInt8, UInt8) = { _, column in
            column < 4 ? (32, 224) : (224, 32)
        }
        let centerSource = try makeNV12PixelBuffer(
            width: 16,
            height: 8,
            chromaLocation: kCVImageBufferChromaLocation_Center,
            luma: luma,
            chroma: chroma
        )
        let leftSource = try makeNV12PixelBuffer(
            width: 16,
            height: 8,
            chromaLocation: kCVImageBufferChromaLocation_Left,
            luma: luma,
            chroma: chroma
        )
        let centerDestination = try makeNV12PixelBuffer(width: 32, height: 16)
        let leftDestination = try makeNV12PixelBuffer(width: 32, height: 16)

        try await ASHDeterministicUpscaleBackend(route: .direct2x).process(
            source: centerSource,
            into: centerDestination
        )
        try await ASHDeterministicUpscaleBackend(route: .direct2x).process(
            source: leftSource,
            into: leftDestination
        )

        XCTAssertNotEqual(readPlane(centerDestination, plane: 1), readPlane(leftDestination, plane: 1))
        XCTAssertEqual(chromaLocation(centerDestination), kCVImageBufferChromaLocation_Center as String)
        XCTAssertEqual(chromaLocation(leftDestination), kCVImageBufferChromaLocation_Left as String)
    }

    func test_backendRejectsMissingChromaSitingInsteadOfGuessing() async throws {
        let source = try makeNV12PixelBuffer(width: 16, height: 8, chromaLocation: nil)
        let destination = try makeNV12PixelBuffer(width: 32, height: 16)
        let backend = ASHDeterministicUpscaleBackend(route: .direct2x)

        do {
            try await backend.process(source: source, into: destination)
            XCTFail("Expected missing chroma siting to fail")
        } catch let error as UpscalerEngineError {
            XCTAssertTrue(String(describing: error).contains("explicit progressive chroma location"))
        }
    }

    func test_backendStatusDoesNotClaimReadyBeforeValidation() {
        XCTAssertEqual(ASHBackendStatus.validating.displayText, "ASH Backend: Validating")
        XCTAssertEqual(ASHBackendStatus.unavailable.displayText, "ASH Backend: Unavailable")
        XCTAssertEqual(ASHBackendStatus.available.displayText, "ASH Backend: Available")
    }

    private func ashAssetRootURL(
        file: StaticString = #filePath
    ) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Mirmir/Resources/ASH")
    }

    private func stridePattern(width: Int, low: Double, high: Double) -> [Double] {
        (0..<width).map { column in column < width / 2 ? low : high }
    }

    private func rampPattern(width: Int) -> [Double] {
        (0..<width).map { Double($0) / Double(max(1, width - 1)) }
    }

    private func branchEvidenceFixtures() throws -> [ASHImage] {
        try [
            ASHImage(width: 32, height: 32) { _, col in
                col < 16 ? 0.05 : 0.95
            },
            ASHImage(width: 32, height: 32) { row, _ in
                row < 16 ? 0.05 : 0.95
            },
            ASHImage(width: 32, height: 32) { row, col in
                (row + col).isMultiple(of: 2) ? 0.0 : 1.0
            },
            ASHImage(width: 32, height: 32) { row, col in
                Double((row * 13 + col * 19) % 255) / 255.0
            },
            ASHImage(width: 32, height: 32) { row, col in
                row == col || row + col == 31 ? 1.0 : 0.02
            },
            ASHImage(width: 32, height: 32) { _, col in
                col.isMultiple(of: 2) ? 0.0 : 1.0
            },
            ASHImage(width: 32, height: 32) { row, _ in
                row.isMultiple(of: 2) ? 0.0 : 1.0
            },
            ASHImage(width: 32, height: 32) { _, _ in
                0.82
            }
        ]
    }

    private func makeNV12PixelBuffer(
        width: Int,
        height: Int,
        chromaLocation: CFString? = kCVImageBufferChromaLocation_Center,
        luma: ((Int, Int) -> UInt8)? = nil,
        chroma: ((Int, Int) -> (UInt8, UInt8))? = nil
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw XCTSkip("Unable to create NV12 pixel buffer")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for col in 0..<width {
                    pointer[row * rowBytes + col] = luma?(row, col) ?? 0
                }
            }
        }

        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<chromaHeight {
                for col in 0..<chromaWidth {
                    let pair = chroma?(row, col) ?? (128, 128)
                    pointer[row * rowBytes + col * 2] = pair.0
                    pointer[row * rowBytes + col * 2 + 1] = pair.1
                }
            }
        }

        if let chromaLocation {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferChromaLocationTopFieldKey,
                chromaLocation,
                .shouldPropagate
            )
        }

        return pixelBuffer
    }

    private func chromaLocation(_ pixelBuffer: CVPixelBuffer) -> String? {
        CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferChromaLocationTopFieldKey,
            nil
        ) as? String
    }

    private func readPlane(_ pixelBuffer: CVPixelBuffer, plane: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
            return []
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * (plane == 1 ? 2 : 1))

        for row in 0..<height {
            let byteCount = plane == 1 ? width * 2 : width
            for offset in 0..<byteCount {
                bytes.append(pointer[row * rowBytes + offset])
            }
        }
        return bytes
    }
}
// swiftlint:enable type_body_length
