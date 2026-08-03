import CoreVideo
import CryptoKit
import Foundation
import XCTest
@testable import Mirmir

/// This test source is injected into an exact clean archive of the frozen P05
/// revision. It must never be compiled from, or linked against, candidate P06
/// source. The quality runner validates this file and the resulting test
/// executable against the identities frozen in the quality contract before it
/// executes the baseline lane.
@available(macOS 15.4, *)
final class ASHP05QualityBaselineCaptureTests: XCTestCase {
    private struct CaptureConfiguration: Decodable {
        let captureDirectory: String
        let corpusManifest: String
        let contractSHA256: String
        let sourceRevision: String
        let sourceTreeIdentitySHA256: String
        let sourceManifestSHA256: String
        let captureSourceSHA256: String
        let executableSHA256: String
        let captureExecutableSHA256: String
    }

    private struct CorpusManifest: Decodable {
        let schemaVersion: String
        let contractSHA256: String
        let cases: [CorpusCase]
    }

    private struct CorpusCase: Decodable {
        let id: String
        let clipID: String
        let frameIndex: Int
        let pixelFormat: String
        let sourceWidth: Int
        let sourceHeight: Int
        let targetWidth: Int
        let targetHeight: Int
        let sourceFile: String
        let sourceByteCount: Int
        let sourceSHA256: String
    }

    private struct BaselineIdentity: Codable {
        let schemaVersion: String
        let implementationVersion: String
        let sourceRevision: String
        let sourceTreeIdentitySHA256: String
        let sourceManifestSHA256: String
        let captureSourceSHA256: String
        let executableSHA256: String
        let captureExecutableSHA256: String
    }

    private struct CaptureCase: Codable {
        let id: String
        let output: String
        let milliseconds: Double
    }

    private struct CaptureManifest: Codable {
        let schemaVersion: String
        let contractSHA256: String
        let corpusManifestSHA256: String
        let baselineIdentity: BaselineIdentity
        let warmupCount: Int
        let cases: [CaptureCase]
    }

    func testCaptureFrozenP05QualityCorpusWhenRequested() async throws {
        let configurationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-p05-quality-baseline-v1")
            .appendingPathComponent("capture-config.json")
        let configuration = try JSONDecoder().decode(
            CaptureConfiguration.self,
            from: Data(contentsOf: configurationURL)
        )

        let output = URL(
            fileURLWithPath: configuration.captureDirectory,
            isDirectory: true
        )
        let artifacts = output.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: artifacts,
            withIntermediateDirectories: true
        )
        let corpusURL = URL(fileURLWithPath: configuration.corpusManifest)
        let corpusRoot = corpusURL.deletingLastPathComponent()
        let corpusData = try Data(contentsOf: corpusURL)
        let corpus = try JSONDecoder().decode(CorpusManifest.self, from: corpusData)
        XCTAssertEqual(corpus.schemaVersion, "mirmir-ash-v4-quality-corpus-v1")
        let expectedContract = configuration.contractSHA256
        XCTAssertEqual(corpus.contractSHA256, expectedContract)

        let clips = Dictionary(grouping: corpus.cases, by: \.clipID)
        let first = try XCTUnwrap(corpus.cases.sorted { $0.id < $1.id }.first)
        try await warmup(first: first, corpusRoot: corpusRoot, count: 5)

        var captured: [CaptureCase] = []
        for clipID in clips.keys.sorted() {
            let cases = clips[clipID]!.sorted { $0.frameIndex < $1.frameIndex }
            XCTAssertEqual(cases.map(\.frameIndex), Array(0..<cases.count))
            let backend = ASHDeterministicUpscaleBackend(
                route: .direct2x,
                runtimeConfiguration: .developmentP05,
                operatorParameters: .p05DevelopmentOnly,
                stateInputEnabled: true
            )
            for record in cases {
                let sourceData = try Data(
                    contentsOf: corpusRoot.appendingPathComponent(record.sourceFile)
                )
                XCTAssertEqual(sourceData.count, record.sourceByteCount)
                XCTAssertEqual(sha256(sourceData), record.sourceSHA256)
                let pixelFormat = try pixelFormat(record.pixelFormat)
                let source = try makeBuffer(
                    width: record.sourceWidth,
                    height: record.sourceHeight,
                    pixelFormat: pixelFormat,
                    bytes: sourceData
                )
                let destination = try makeBuffer(
                    width: record.targetWidth,
                    height: record.targetHeight,
                    pixelFormat: pixelFormat
                )
                let milliseconds = try await measured {
                    let completion = try await backend.process(
                        source: source,
                        into: destination,
                        context: ASHUpscaleFrameContext(
                            frameIndex: record.frameIndex,
                            presentationTimestampValue: Int64(record.frameIndex),
                            presentationTimestampTimescale: 30
                        )
                    )
                    completion.finishAfterAppend()
                }
                let relative = "artifacts/\(record.id)-baseline_p05.nv12"
                try visibleBytes(destination).write(
                    to: output.appendingPathComponent(relative),
                    options: .atomic
                )
                captured.append(CaptureCase(
                    id: record.id,
                    output: relative,
                    milliseconds: milliseconds
                ))
            }
        }

        let manifest = CaptureManifest(
            schemaVersion: "mirmir-ash-v4-quality-p05-capture-v1",
            contractSHA256: expectedContract,
            corpusManifestSHA256: sha256(corpusData),
            baselineIdentity: BaselineIdentity(
                schemaVersion: "mirmir-ash-v4-p05-baseline-identity-v1",
                implementationVersion: "ash-p05-cpu-reference-preview",
                sourceRevision: configuration.sourceRevision,
                sourceTreeIdentitySHA256:
                    configuration.sourceTreeIdentitySHA256,
                sourceManifestSHA256: configuration.sourceManifestSHA256,
                captureSourceSHA256: configuration.captureSourceSHA256,
                executableSHA256: configuration.executableSHA256,
                captureExecutableSHA256:
                    configuration.captureExecutableSHA256
            ),
            warmupCount: 5,
            cases: captured.sorted { $0.id < $1.id }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: output.appendingPathComponent("p05-capture-manifest.json"),
            options: .atomic
        )
    }

    private func warmup(
        first: CorpusCase,
        corpusRoot: URL,
        count: Int
    ) async throws {
        let format = try pixelFormat(first.pixelFormat)
        let source = try makeBuffer(
            width: first.sourceWidth,
            height: first.sourceHeight,
            pixelFormat: format,
            bytes: Data(contentsOf: corpusRoot.appendingPathComponent(first.sourceFile))
        )
        let backend = ASHDeterministicUpscaleBackend(
            route: .direct2x,
            runtimeConfiguration: .developmentP05,
            operatorParameters: .p05DevelopmentOnly,
            stateInputEnabled: true
        )
        for index in 0..<count {
            let destination = try makeBuffer(
                width: first.targetWidth,
                height: first.targetHeight,
                pixelFormat: format
            )
            let completion = try await backend.process(
                source: source,
                into: destination,
                context: ASHUpscaleFrameContext(frameIndex: index)
            )
            completion.finishAfterAppend()
        }
    }

    private func pixelFormat(_ id: String) throws -> OSType {
        switch id {
        case "420v": kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case "420f": kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        default: throw XCTSkip("unsupported quality storage \(id)")
        }
    }

    private func makeBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        bytes: Data? = nil
    ) throws -> CVPixelBuffer {
        let buffer = try SyntheticNV12PixelBuffer.make(
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )
        if let bytes {
            let expected = width * height * 3 / 2
            guard bytes.count == expected else {
                throw SyntheticPixelBufferError.invalidNV12Geometry(
                    width: width,
                    height: height,
                    rowAlignment: bytes.count
                )
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            var offset = 0
            for plane in 0..<2 {
                let planeWidth = CVPixelBufferGetWidthOfPlane(buffer, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
                let components = plane == 0 ? 1 : 2
                let visibleRowBytes = planeWidth * components
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
                    .assumingMemoryBound(to: UInt8.self)
                bytes.withUnsafeBytes { raw in
                    let source = raw.bindMemory(to: UInt8.self)
                    for row in 0..<planeHeight {
                        base.advanced(by: row * stride).update(
                            from: source.baseAddress!.advanced(by: offset),
                            count: visibleRowBytes
                        )
                        offset += visibleRowBytes
                    }
                }
            }
        }
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferFieldCountKey,
            NSNumber(value: 1),
            .shouldPropagate
        )
        return buffer
    }

    private func visibleBytes(_ buffer: CVPixelBuffer) throws -> Data {
        Data(
            try SyntheticNV12PixelBuffer.visibleBytes(buffer, plane: 0)
                + SyntheticNV12PixelBuffer.visibleBytes(buffer, plane: 1)
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func measured(
        _ operation: () async throws -> Void
    ) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await operation()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }
}
