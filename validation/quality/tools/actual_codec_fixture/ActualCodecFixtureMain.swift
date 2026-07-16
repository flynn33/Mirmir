import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation

private struct Arguments {
    let sourceURL: URL
    let sourceLockURL: URL
    let fixtureURL: URL
    let reportURL: URL

    init(_ values: [String]) throws {
        var options: [String: String] = [:]
        var index = 0
        while index < values.count {
            let key = values[index]
            guard key.hasPrefix("--"), index + 1 < values.count else {
                throw FixtureError.invalidArgument("arguments require --name value pairs")
            }
            guard options.updateValue(values[index + 1], forKey: key) == nil else {
                throw FixtureError.invalidArgument("duplicate argument \(key)")
            }
            index += 2
        }
        let required = ["--source", "--source-lock", "--fixture", "--report"]
        let missing = required.filter { options[$0] == nil }
        guard missing.isEmpty else {
            throw FixtureError.invalidArgument("missing arguments: \(missing.joined(separator: ", "))")
        }
        sourceURL = URL(fileURLWithPath: options["--source"]!)
        sourceLockURL = URL(fileURLWithPath: options["--source-lock"]!)
        fixtureURL = URL(fileURLWithPath: options["--fixture"]!)
        reportURL = URL(fileURLWithPath: options["--report"]!)
    }
}

private func readSourceLock(_ url: URL) throws -> SourceFixtureLock {
    try JSONDecoder().decode(SourceFixtureLock.self, from: Data(contentsOf: url))
}

private func validateSource(
    payload: Data,
    lock: SourceFixtureLock
) throws {
    guard lock.fixtureId == "actual-h264-software-nv12-v1",
          lock.pixelLayout.pixelFormat == "420v",
          lock.pixelLayout.range == "video",
          lock.pixelLayout.colorPrimaries == String(kCVImageBufferColorPrimaries_ITU_R_709_2),
          lock.pixelLayout.transferFunction == String(kCVImageBufferTransferFunction_ITU_R_709_2),
          lock.pixelLayout.yCbCrMatrix == String(kCVImageBufferYCbCrMatrix_ITU_R_709_2),
          lock.pixelLayout.chromaLocationTopField == String(kCVImageBufferChromaLocation_Left),
          lock.pixelLayout.chromaLocationBottomField == String(kCVImageBufferChromaLocation_Left),
          lock.pixelLayout.width > 0,
          lock.pixelLayout.height > 0,
          lock.pixelLayout.width.isMultiple(of: 2),
          lock.pixelLayout.height.isMultiple(of: 2),
          lock.frameCount == lock.frames.count,
          lock.frameCount == 3 else {
        throw FixtureError.invalidFixture("source lock geometry or identity is invalid")
    }
    guard payload.count == lock.payloadSizeBytes, sha256(payload) == lock.payloadSha256 else {
        throw FixtureError.invalidFixture("source NV12 payload does not match its lock")
    }
    let width = lock.pixelLayout.width
    let height = lock.pixelLayout.height
    let frameSize = width * height * 3 / 2
    guard payload.count == frameSize * lock.frameCount else {
        throw FixtureError.invalidFixture("source NV12 payload size is inconsistent")
    }
    for (position, frame) in lock.frames.enumerated() {
        guard frame.index == position,
              frame.presentationTime.cmTime.isNumeric,
              frame.duration.cmTime.isNumeric,
              CMTimeCompare(frame.duration.cmTime, .zero) > 0 else {
            throw FixtureError.invalidFixture("source frame timing or index is invalid")
        }
        let offset = position * frameSize
        let luma = payload.subdata(in: offset..<(offset + width * height))
        let uvStart = offset + width * height
        let uv = payload.subdata(in: uvStart..<(offset + frameSize))
        var cb = Data()
        var cr = Data()
        cb.reserveCapacity(width * height / 4)
        cr.reserveCapacity(width * height / 4)
        for byteIndex in stride(from: 0, to: uv.count, by: 2) {
            cb.append(uv[byteIndex])
            cr.append(uv[byteIndex + 1])
        }
        let activeHashes = PlaneHashes(
            luma: sha256(luma),
            chromaBlue: sha256(cb),
            chromaRed: sha256(cr)
        )
        guard activeHashes == frame.activeRowSha256,
              sha256(payload.subdata(in: offset..<(offset + frameSize))) == frame.frameNv12Sha256 else {
            throw FixtureError.invalidFixture("source frame \(position) hashes do not match")
        }
    }
}

private func timesEqual(_ lhs: ExactTime, _ rhs: LockedTime) -> Bool {
    CMTimeCompare(lhs.cmTime, rhs.cmTime) == 0
}

private func pixels(_ run: DecodeRunEvidence) -> [PlaneHashes] {
    run.frames.map(\.activeRowSha256)
}

private func allRunsEqual(_ runs: [DecodeRunEvidence]) -> Bool {
    guard let first = runs.first else { return false }
    return runs.dropFirst().allSatisfy { pixels($0) == pixels(first) }
}

private func exactTimingPreserved(
    runs: [DecodeRunEvidence],
    source: SourceFixtureLock
) -> Bool {
    runs.allSatisfy { run in
        run.frames.count == source.frames.count && zip(run.frames, source.frames).allSatisfy {
            timesEqual($0.presentationTime, $1.presentationTime)
                && timesEqual($0.duration, $1.duration)
        }
    }
}

private func attachmentsAreRecorded(_ routes: [DecoderRouteEvidence]) -> Bool {
    routes.allSatisfy { route in
        route.runs.allSatisfy { run in
            run.frames.allSatisfy { frame in
                frame.attachments.colorPrimaries
                    == String(kCVImageBufferColorPrimaries_ITU_R_709_2)
                    && frame.attachments.transferFunction
                        == String(kCVImageBufferTransferFunction_ITU_R_709_2)
                    && frame.attachments.yCbCrMatrix
                        == String(kCVImageBufferYCbCrMatrix_ITU_R_709_2)
                    && frame.attachments.chromaLocationTopField
                        == String(kCVImageBufferChromaLocation_Left)
                    && frame.attachments.chromaLocationBottomField
                        == String(kCVImageBufferChromaLocation_Left)
                    && frame.attachments.range == "video"
            }
        }
    }
}

private func outputEndpoint(_ lock: SourceFixtureLock) throws -> CMTime {
    guard let final = lock.frames.last else {
        throw FixtureError.invalidFixture("source lock contains no frames")
    }
    return CMTimeAdd(final.presentationTime.cmTime, final.duration.cmTime)
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw FixtureError.invalidArgument("refusing to overwrite existing report \(url.path)")
    }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value) + Data([0x0a])
    let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
        ".\(url.lastPathComponent).partial-\(UUID().uuidString)"
    )
    try data.write(to: temporaryURL, options: .atomic)
    try FileManager.default.moveItem(at: temporaryURL, to: url)
}

private func preservedFailureURL(for reportURL: URL) -> URL {
    let directory = reportURL.deletingLastPathComponent()
    let stem = reportURL.deletingPathExtension().lastPathComponent
    for index in 1...9999 {
        let candidate = directory.appendingPathComponent("\(stem).failed-\(index).json")
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
    }
    return directory.appendingPathComponent("\(stem).failed-overflow.json")
}

private struct VerifiedRoutes {
    let routes: [DecoderRouteEvidence]
    let verification: VerificationEvidence
}

private func decoderRoutes(
    codec: String,
    softwareRuns: [DecodeRunEvidence],
    productRuns: [DecodeRunEvidence],
    accelerationPropertyAvailable: Bool
) -> [DecoderRouteEvidence] {
    let softwareRoute = DecoderRouteEvidence(
        route: "videotoolbox_software_nv12",
        identity: DecoderIdentity(
            framework: "VideoToolbox",
            sessionType: "VTDecompressionSession",
            codec: codec,
            hardwareAccelerationControl: accelerationPropertyAvailable
                ? "explicitly disabled and queried false for every run"
                : "explicitly disabled; acceleration property unsupported for at least one run",
            hardwareAccelerated: false,
            hardwareAccelerationPropertyAvailable: accelerationPropertyAvailable,
            publicDecoderIdentifier: "not_exposed_by_public_API"
        ),
        runs: softwareRuns
    )
    let productRoute = DecoderRouteEvidence(
        route: "avassetreader_product_nv12",
        identity: DecoderIdentity(
            framework: "AVFoundation",
            sessionType: "AVAssetReaderTrackOutput",
            codec: codec,
            hardwareAccelerationControl: "not exposed by AVAssetReaderTrackOutput",
            hardwareAccelerated: nil,
            hardwareAccelerationPropertyAvailable: nil,
            publicDecoderIdentifier: "not_exposed_by_public_API"
        ),
        runs: productRuns
    )
    return [softwareRoute, productRoute]
}

private func collectVerifiedRoutes(
    fixtureURL: URL,
    descriptor: AssetDescriptor,
    sourceLock: SourceFixtureLock
) async throws -> VerifiedRoutes {
    var softwareRuns: [DecodeRunEvidence] = []
    var decoderHardwareValues: [Bool?] = []
    var productRuns: [DecodeRunEvidence] = []
    for index in 0..<3 {
        let (run, hardwareAccelerated) = try await softwareDecodeRun(
            url: fixtureURL,
            runIndex: index,
            expectedCount: sourceLock.frameCount
        )
        softwareRuns.append(run)
        decoderHardwareValues.append(hardwareAccelerated)
        productRuns.append(
            try await productReaderDecodeRun(
                url: fixtureURL,
                runIndex: index,
                expectedCount: sourceLock.frameCount
            )
        )
    }
    guard decoderHardwareValues.allSatisfy({ $0 != true }) else {
        throw FixtureError.failed("software-forced decode used hardware acceleration")
    }
    let propertyAvailable = decoderHardwareValues.allSatisfy { $0 != nil }
    let routes = decoderRoutes(
        codec: descriptor.codec,
        softwareRuns: softwareRuns,
        productRuns: productRuns,
        accelerationPropertyAvailable: propertyAvailable
    )
    let softwareEqual = allRunsEqual(softwareRuns)
    let productEqual = allRunsEqual(productRuns)
    let crossRouteEqual = softwareRuns.first.map(pixels) == productRuns.first.map(pixels)
    let softwareTiming = exactTimingPreserved(runs: softwareRuns, source: sourceLock)
    let productTiming = exactTimingPreserved(runs: productRuns, source: sourceLock)
    let dimensionsPreserved = routes.allSatisfy { route in
        route.runs.allSatisfy { run in
            run.frames.allSatisfy {
                $0.width == sourceLock.pixelLayout.width
                    && $0.height == sourceLock.pixelLayout.height
            }
        }
    }
    let pixelFormatPreserved = routes.allSatisfy { route in
        route.runs.allSatisfy { run in
            run.frames.allSatisfy { $0.pixelFormat == "420v" }
        }
    }
    let attachmentsRecorded = attachmentsAreRecorded(routes)
    guard softwareEqual,
          productEqual,
          crossRouteEqual,
          softwareTiming,
          productTiming,
          dimensionsPreserved,
          pixelFormatPreserved,
          attachmentsRecorded else {
        throw FixtureError.failed(
            "decoded fixture invariant failed: software_repeat=\(softwareEqual), "
                + "product_repeat=\(productEqual), cross_route=\(crossRouteEqual), "
                + "software_timing=\(softwareTiming), product_timing=\(productTiming), "
                + "dimensions=\(dimensionsPreserved), pixel_format=\(pixelFormatPreserved), "
                + "attachments=\(attachmentsRecorded)"
        )
    }
    return VerifiedRoutes(
        routes: routes,
        verification: VerificationEvidence(
            softwareDecodeRunCount: softwareRuns.count,
            productReaderRunCount: productRuns.count,
            softwareRunsPixelIdentical: softwareEqual,
            productReaderRunsPixelIdentical: productEqual,
            crossRoutePixelIdentical: crossRouteEqual,
            exactTimingPreserved: softwareTiming && productTiming,
            dimensionsPreserved: dimensionsPreserved,
            pixelFormatPreserved: pixelFormatPreserved,
            attachmentsRecorded: attachmentsRecorded,
            rowPaddingExcluded: true
        )
    )
}

private func run(_ arguments: Arguments) async throws {
    let payload = try Data(contentsOf: arguments.sourceURL)
    let sourceLockData = try Data(contentsOf: arguments.sourceLockURL)
    let sourceLock = try readSourceLock(arguments.sourceLockURL)
    try validateSource(payload: payload, lock: sourceLock)

    let compression = try encodeAndMux(
        sourcePayload: payload,
        sourceLock: sourceLock,
        outputURL: arguments.fixtureURL
    )
    let descriptor = try await loadAssetDescriptor(url: arguments.fixtureURL)
    guard descriptor.codec == "avc1",
          descriptor.width == sourceLock.pixelLayout.width,
          descriptor.height == sourceLock.pixelLayout.height,
          CMTimeCompare(descriptor.duration, try outputEndpoint(sourceLock)) == 0 else {
        throw FixtureError.invalidFixture("reopened H.264 fixture geometry or duration is invalid")
    }
    guard descriptor.attachments.colorPrimaries
            == String(kCVImageBufferColorPrimaries_ITU_R_709_2),
          descriptor.attachments.transferFunction
            == String(kCVImageBufferTransferFunction_ITU_R_709_2),
          descriptor.attachments.yCbCrMatrix
            == String(kCVImageBufferYCbCrMatrix_ITU_R_709_2),
          descriptor.attachments.chromaLocationTopField
            == String(kCVImageBufferChromaLocation_Left),
          descriptor.attachments.chromaLocationBottomField
            == String(kCVImageBufferChromaLocation_Left),
          descriptor.attachments.range == "video" else {
        throw FixtureError.invalidFixture("encoded format attachments are not locked Left-sited BT.709 video-range metadata")
    }

    let verifiedRoutes = try await collectVerifiedRoutes(
        fixtureURL: arguments.fixtureURL,
        descriptor: descriptor,
        sourceLock: sourceLock
    )

    let fixtureData = try Data(contentsOf: arguments.fixtureURL)
    let fixtureHash = sha256(fixtureData)
    let report = ActualCodecFixtureReport(
        schemaVersion: "1.0.0",
        artifactKind: "actual_codec_fixture",
        fixtureId: sourceLock.fixtureId,
        status: "pass",
        source: SourceEvidence(
            payloadPath: arguments.sourceURL.lastPathComponent,
            payloadSha256: sourceLock.payloadSha256,
            payloadSizeBytes: sourceLock.payloadSizeBytes,
            sourceLockPath: arguments.sourceLockURL.lastPathComponent,
            sourceLockSha256: sha256(sourceLockData),
            degradationProfileId: sourceLock.source.degradationProfileId,
            degradationPolicySha256: sourceLock.source.degradationPolicySha256
        ),
        fixture: EncodedFixtureEvidence(
            path: arguments.fixtureURL.lastPathComponent,
            sha256: fixtureHash,
            sizeBytes: fixtureData.count,
            container: "mp4",
            codec: descriptor.codec,
            width: descriptor.width,
            height: descriptor.height,
            frameCount: sourceLock.frameCount,
            duration: ExactTime(descriptor.duration),
            formatAttachments: descriptor.attachments
        ),
        encoder: encoderEvidence(compression),
        decoderRoutes: verifiedRoutes.routes,
        verification: verifiedRoutes.verification,
        environment: environmentEvidence(),
        integration: IntegrationEvidence(
            degradationLockProfile: DegradationLockIntegration(
                id: sourceLock.fixtureId,
                kind: "actual_codec",
                version: "1.0.0",
                sourceProfileId: sourceLock.source.degradationProfileId,
                fixturePath: arguments.fixtureURL.lastPathComponent,
                fixtureSha256: fixtureHash,
                evidencePath: arguments.reportURL.lastPathComponent,
                decodedPixelsDeterministic: true
            ),
            benchmarkDryRunFields: BenchmarkIntegration(
                comparisonDomainsExecuted: ["container_decoded"],
                actualCodecFixtureUsed: true,
                actualCodecFixtureId: sourceLock.fixtureId,
                containerDecodedFrameCount: sourceLock.frameCount,
                holdoutAccessed: false
            )
        ),
        limitations: LimitationEvidence(
            crossOsBitstreamStabilityClaimed: false,
            regenerationBitstreamStabilityClaimed: false,
            bitstreamScope: "the committed MP4 alone is hash-locked; regeneration byte identity is not asserted on the same or a different environment",
            productReaderAccelerationVisibility: "AVAssetReaderTrackOutput does not expose decoder selection or acceleration state"
        )
    )
    try writeJSON(report, to: arguments.reportURL)
    print("actual codec fixture verification passed: \(fixtureHash)")
}

@main
struct ActualCodecFixtureMain {
    static func main() async {
        let arguments: Arguments
        do {
            arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("argument error: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
        do {
            try await run(arguments)
        } catch {
            let failure = FailureEvidence(
                errorType: String(reflecting: type(of: error)),
                message: String(describing: error),
                requestedFixturePath: arguments.fixtureURL.path
            )
            let failureURL = preservedFailureURL(for: arguments.reportURL)
            do {
                try writeJSON(failure, to: failureURL)
                FileHandle.standardError.write(
                    Data("fixture verification failed; evidence preserved at \(failureURL.path): \(error)\n".utf8)
                )
            } catch let preservationError {
                FileHandle.standardError.write(
                    Data("fixture verification failed: \(error); failure evidence error: \(preservationError)\n".utf8)
                )
            }
            exit(EXIT_FAILURE)
        }
    }
}
