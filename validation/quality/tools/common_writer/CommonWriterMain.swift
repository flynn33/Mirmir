import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation

private struct CommonWriterArguments {
    let sourceURL: URL
    let sourceLockURL: URL
    let encodedURL: URL
    let reportURL: URL
    let decodedDirectoryURL: URL

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
        let required = ["--source", "--source-lock", "--encoded", "--report", "--decoded-directory"]
        let missing = required.filter { options[$0] == nil }
        guard missing.isEmpty else {
            throw FixtureError.invalidArgument("missing arguments: \(missing.joined(separator: ", "))")
        }
        sourceURL = URL(fileURLWithPath: options["--source"]!)
        sourceLockURL = URL(fileURLWithPath: options["--source-lock"]!)
        encodedURL = URL(fileURLWithPath: options["--encoded"]!)
        reportURL = URL(fileURLWithPath: options["--report"]!)
        decodedDirectoryURL = URL(fileURLWithPath: options["--decoded-directory"]!)
    }
}

private func validateOutputEndpoints(_ arguments: CommonWriterArguments) throws {
    let manager = FileManager.default
    for url in [arguments.encodedURL, arguments.reportURL, arguments.decodedDirectoryURL] {
        guard !manager.fileExists(atPath: url.path) else {
            throw FixtureError.invalidArgument("refusing to overwrite existing output \(url.path)")
        }
    }
    guard arguments.encodedURL.pathExtension.lowercased() == "mp4" else {
        throw FixtureError.invalidArgument("encoded output must use the .mp4 extension")
    }
}

private func validateSource(
    payload: Data,
    sourceURL: URL,
    lock: CommonWriterSourceLock
) throws {
    guard lock.schemaVersion == "1.0.0",
          lock.artifactKind == "common_writer_source_lock",
          !lock.sourceId.isEmpty,
          lock.payloadPath == sourceURL.lastPathComponent,
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
          lock.frameCount >= 1,
          lock.frames.count == lock.frameCount else {
        throw FixtureError.invalidFixture("source lock identity, layout, or frame count is invalid")
    }
    guard payload.count == lock.payloadSizeBytes,
          sha256(payload) == lock.payloadSha256 else {
        throw FixtureError.invalidFixture("source NV12 payload does not match its lock")
    }
    let width = lock.pixelLayout.width
    let height = lock.pixelLayout.height
    let lumaSize = width * height
    let frameSize = lumaSize * 3 / 2
    guard payload.count == frameSize * lock.frameCount else {
        throw FixtureError.invalidFixture("source NV12 payload size is inconsistent with geometry")
    }
    var caseIds = Set<String>()
    var previousPresentationTime: CMTime?
    for (position, frame) in lock.frames.enumerated() {
        let presentationTime = frame.presentationTime.cmTime
        let duration = frame.duration.cmTime
        guard frame.index == position,
              !frame.caseId.isEmpty,
              caseIds.insert(frame.caseId).inserted,
              presentationTime.isNumeric,
              duration.isNumeric,
              CMTimeCompare(presentationTime, .zero) >= 0,
              CMTimeCompare(duration, .zero) > 0 else {
            throw FixtureError.invalidFixture("source frame \(position) identity or timing is invalid")
        }
        if let previousPresentationTime,
           CMTimeCompare(presentationTime, previousPresentationTime) <= 0 {
            throw FixtureError.invalidFixture("source presentation times are not strictly increasing")
        }
        previousPresentationTime = presentationTime
        let offset = position * frameSize
        let framePayload = payload.subdata(in: offset..<(offset + frameSize))
        let luma = framePayload.subdata(in: 0..<lumaSize)
        let chroma = framePayload.subdata(in: lumaSize..<frameSize)
        var chromaBlue = Data()
        var chromaRed = Data()
        chromaBlue.reserveCapacity(lumaSize / 4)
        chromaRed.reserveCapacity(lumaSize / 4)
        for byteIndex in stride(from: 0, to: chroma.count, by: 2) {
            chromaBlue.append(chroma[byteIndex])
            chromaRed.append(chroma[byteIndex + 1])
        }
        let hashes = PlaneHashes(
            luma: sha256(luma),
            chromaBlue: sha256(chromaBlue),
            chromaRed: sha256(chromaRed)
        )
        guard hashes == frame.activeRowSha256,
              sha256(framePayload) == frame.frameNv12Sha256 else {
            throw FixtureError.invalidFixture("source frame \(position) hashes do not match")
        }
    }
}

private func encodingLock(_ source: CommonWriterSourceLock) -> SourceFixtureLock {
    SourceFixtureLock(
        fixtureId: source.sourceId,
        source: CodecSourceOrigin(
            degradationProfileId: source.sourceId,
            degradationPolicySha256: source.payloadSha256
        ),
        pixelLayout: source.pixelLayout,
        frameCount: source.frameCount,
        frames: source.frames.map {
            SourceFrameLock(
                index: $0.index,
                presentationTime: $0.presentationTime,
                duration: $0.duration,
                activeRowSha256: $0.activeRowSha256,
                frameNv12Sha256: $0.frameNv12Sha256
            )
        },
        payloadSizeBytes: source.payloadSizeBytes,
        payloadSha256: source.payloadSha256
    )
}

private func resolvedDuration(
    sample: CMSampleBuffer,
    nextSample: CMSampleBuffer?,
    trackEnd: CMTime
) throws -> CMTime {
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
    let sampleDuration = CMSampleBufferGetDuration(sample)
    let duration: CMTime
    if sampleDuration.isNumeric, CMTimeCompare(sampleDuration, .zero) > 0 {
        duration = sampleDuration
    } else if let nextSample {
        duration = CMTimeSubtract(
            CMSampleBufferGetPresentationTimeStamp(nextSample),
            presentationTime
        )
    } else {
        duration = CMTimeSubtract(trackEnd, presentationTime)
    }
    guard duration.isNumeric, CMTimeCompare(duration, .zero) > 0 else {
        throw FixtureError.invalidFixture("decoded frame duration cannot be resolved")
    }
    return duration
}

private func activeNV12Payload(_ pixelBuffer: CVPixelBuffer) throws -> Data {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == expectedPixelFormat,
          CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
        throw FixtureError.invalidFixture("decoded buffer is not video-range NV12")
    }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    guard lockStatus == kCVReturnSuccess else {
        throw FixtureError.operation("CVPixelBufferLockBaseAddress", lockStatus)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
          let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
        throw FixtureError.invalidFixture("decoded NV12 plane base address is absent")
    }
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    guard lumaStride >= width,
          chromaStride >= width,
          CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) == height,
          CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) * 2 == height else {
        throw FixtureError.invalidFixture("decoded NV12 plane geometry is inconsistent")
    }
    var payload = Data()
    payload.reserveCapacity(width * height * 3 / 2)
    for row in 0..<height {
        payload.append(Data(bytes: lumaBase.advanced(by: row * lumaStride), count: width))
    }
    for row in 0..<(height / 2) {
        payload.append(Data(bytes: chromaBase.advanced(by: row * chromaStride), count: width))
    }
    return payload
}

private func attachmentSetIsComplete(_ value: AttachmentEvidence) -> Bool {
    value.colorPrimaries == String(kCVImageBufferColorPrimaries_ITU_R_709_2)
        && value.transferFunction == String(kCVImageBufferTransferFunction_ITU_R_709_2)
        && value.yCbCrMatrix == String(kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        && value.chromaLocationTopField == String(kCVImageBufferChromaLocation_Left)
        && value.chromaLocationBottomField == String(kCVImageBufferChromaLocation_Left)
        && value.range == "video"
}

private func decodedFrames(
    descriptor: AssetDescriptor,
    source: CommonWriterSourceLock
) throws -> [(CommonWriterDecodedFrame, Data)] {
    let outputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: expectedPixelFormat),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    let samples = try copySamples(descriptor: descriptor, outputSettings: outputSettings)
    guard samples.count == source.frameCount else {
        throw FixtureError.invalidFixture(
            "product reader decoded \(samples.count) frames; expected \(source.frameCount)"
        )
    }
    return try samples.enumerated().map { index, sample in
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            throw FixtureError.invalidFixture("product reader sample image buffer is absent")
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = try resolvedDuration(
            sample: sample,
            nextSample: index + 1 < samples.count ? samples[index + 1] : nil,
            trackEnd: descriptor.trackEnd
        )
        let sourceFrame = source.frames[index]
        guard CMTimeCompare(presentationTime, sourceFrame.presentationTime.cmTime) == 0,
              CMTimeCompare(duration, sourceFrame.duration.cmTime) == 0 else {
            throw FixtureError.invalidFixture("decoded frame \(index) timing differs from its source lock")
        }
        let payload = try activeNV12Payload(pixelBuffer)
        let frameEvidence = try decodedFrameEvidence(
            pixelBuffer: pixelBuffer,
            index: index,
            presentationTime: presentationTime,
            duration: duration
        )
        guard frameEvidence.width == source.pixelLayout.width,
              frameEvidence.height == source.pixelLayout.height,
              frameEvidence.pixelFormat == "420v",
              payload.count == source.pixelLayout.width * source.pixelLayout.height * 3 / 2,
              attachmentSetIsComplete(frameEvidence.attachments) else {
            throw FixtureError.invalidFixture("decoded frame \(index) format evidence is incomplete")
        }
        let lumaSize = frameEvidence.width * frameEvidence.height
        let luma = payload.subdata(in: 0..<lumaSize)
        let chroma = payload.subdata(in: lumaSize..<payload.count)
        let payloadHashes = PlaneHashes(
            luma: sha256(luma),
            chromaBlue: sha256(Data(chroma.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil })),
            chromaRed: sha256(Data(chroma.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? nil : $0.element }))
        )
        guard payloadHashes == frameEvidence.activeRowSha256 else {
            throw FixtureError.invalidFixture("decoded frame \(index) payload hashes are inconsistent")
        }
        let payloadPath = String(format: "frame-%06d.nv12", index)
        return (
            CommonWriterDecodedFrame(
                caseId: sourceFrame.caseId,
                index: index,
                presentationTime: frameEvidence.presentationTime,
                duration: frameEvidence.duration,
                width: frameEvidence.width,
                height: frameEvidence.height,
                pixelFormat: frameEvidence.pixelFormat,
                payloadPath: payloadPath,
                payloadSizeBytes: payload.count,
                payloadSha256: sha256(payload),
                activeRowSha256: frameEvidence.activeRowSha256,
                attachments: frameEvidence.attachments
            ),
            payload
        )
    }
}

private func endpoint(_ source: CommonWriterSourceLock) throws -> CMTime {
    guard let final = source.frames.last else {
        throw FixtureError.invalidFixture("source lock has no frames")
    }
    return CMTimeAdd(final.presentationTime.cmTime, final.duration.cmTime)
}

private func writeNewJSON<T: Encodable>(_ value: T, to url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw FixtureError.invalidArgument("refusing to overwrite existing JSON \(url.path)")
    }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let payload = try encoder.encode(value) + Data([0x0a])
    let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
        ".\(url.lastPathComponent).partial-\(UUID().uuidString)"
    )
    try payload.write(to: temporaryURL, options: .withoutOverwriting)
    try FileManager.default.moveItem(at: temporaryURL, to: url)
}

private func failureURL(for reportURL: URL) -> URL {
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

private func exportDecodedPayloads(
    _ frames: [(CommonWriterDecodedFrame, Data)],
    to directory: URL
) throws {
    guard !FileManager.default.fileExists(atPath: directory.path) else {
        throw FixtureError.invalidArgument("refusing to overwrite decoded directory \(directory.path)")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (frame, payload) in frames {
        let target = directory.appendingPathComponent(frame.payloadPath)
        try payload.write(to: target, options: .withoutOverwriting)
        let persisted = try Data(contentsOf: target)
        guard persisted.count == frame.payloadSizeBytes,
              sha256(persisted) == frame.payloadSha256 else {
            throw FixtureError.failed("decoded frame \(frame.index) persistence verification failed")
        }
    }
}

private func run(_ arguments: CommonWriterArguments) async throws {
    try validateOutputEndpoints(arguments)
    let sourcePayload = try Data(contentsOf: arguments.sourceURL)
    let sourceLockData = try Data(contentsOf: arguments.sourceLockURL)
    let sourceLock = try JSONDecoder().decode(CommonWriterSourceLock.self, from: sourceLockData)
    try validateSource(payload: sourcePayload, sourceURL: arguments.sourceURL, lock: sourceLock)
    let compression = try encodeAndMux(
        sourcePayload: sourcePayload,
        sourceLock: encodingLock(sourceLock),
        outputURL: arguments.encodedURL
    )
    let descriptor = try await loadAssetDescriptor(url: arguments.encodedURL)
    guard descriptor.codec == "avc1",
          descriptor.width == sourceLock.pixelLayout.width,
          descriptor.height == sourceLock.pixelLayout.height,
          CMTimeCompare(descriptor.duration, try endpoint(sourceLock)) == 0,
          attachmentSetIsComplete(descriptor.attachments) else {
        throw FixtureError.invalidFixture("reopened H.264 container evidence is inconsistent")
    }
    let decoded = try decodedFrames(descriptor: descriptor, source: sourceLock)
    try exportDecodedPayloads(decoded, to: arguments.decodedDirectoryURL)
    let encodedPayload = try Data(contentsOf: arguments.encodedURL)
    let report = CommonWriterReport(
        schemaVersion: "1.0.0",
        artifactKind: "common_writer_actual_codec",
        status: "pass",
        source: CommonWriterSourceEvidence(
            sourceId: sourceLock.sourceId,
            payloadPath: arguments.sourceURL.lastPathComponent,
            payloadSha256: sourceLock.payloadSha256,
            payloadSizeBytes: sourceLock.payloadSizeBytes,
            sourceLockPath: arguments.sourceLockURL.lastPathComponent,
            sourceLockSha256: sha256(sourceLockData),
            sourceLockSizeBytes: sourceLockData.count,
            pixelLayout: sourceLock.pixelLayout,
            frameCount: sourceLock.frameCount,
            frames: sourceLock.frames
        ),
        encoded: CommonWriterEncodedEvidence(
            path: arguments.encodedURL.lastPathComponent,
            sha256: sha256(encodedPayload),
            sizeBytes: encodedPayload.count,
            container: "mp4",
            codec: descriptor.codec,
            width: descriptor.width,
            height: descriptor.height,
            frameCount: sourceLock.frameCount,
            duration: ExactTime(descriptor.duration),
            formatAttachments: descriptor.attachments
        ),
        encoder: encoderEvidence(compression),
        decoder: CommonWriterDecoderEvidence(
            framework: "AVFoundation",
            sessionType: "AVAssetReaderTrackOutput",
            codec: descriptor.codec,
            pixelFormat: "420v",
            payloadLayout: "active_row_nv12_without_padding",
            frameCount: decoded.count,
            frames: decoded.map(\.0)
        ),
        verification: CommonWriterVerification(
            sourceLockValid: true,
            sourceBytesMatchLock: true,
            encodedContainerReopened: true,
            actualCodecContainerUsed: true,
            exactCaseOrderPreserved: decoded.map(\.0.caseId) == sourceLock.frames.map(\.caseId),
            exactTimingPreserved: true,
            dimensionsPreserved: true,
            pixelFormatPreserved: true,
            attachmentsRecorded: true,
            rowPaddingExcluded: true,
            decodedPayloadsByteBound: true,
            frameCountPreserved: decoded.count == sourceLock.frameCount
        ),
        environment: environmentEvidence(),
        limitations: CommonWriterLimitations(
            mp4ByteIdentityAcrossRunsClaimed: false,
            decodedPixelRepeatabilityScope: "repeatability is established only when separate recorded runs have matching decoded payload hashes",
            decoderAccelerationVisibility: "AVAssetReaderTrackOutput does not expose decoder selection or acceleration state"
        )
    )
    guard report.verification.exactCaseOrderPreserved,
          report.verification.frameCountPreserved else {
        throw FixtureError.failed("post-decode order or frame-count verification failed")
    }
    try writeNewJSON(report, to: arguments.reportURL)
    print("common writer verification passed: \(report.encoded.sha256)")
}

@main
struct CommonWriterMain {
    static func main() async {
        let arguments: CommonWriterArguments
        do {
            arguments = try CommonWriterArguments(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("argument error: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
        do {
            try await run(arguments)
        } catch {
            let failure = CommonWriterFailure(
                errorType: String(reflecting: type(of: error)),
                message: String(describing: error),
                sourcePath: arguments.sourceURL.path,
                sourceLockPath: arguments.sourceLockURL.path,
                requestedEncodedPath: arguments.encodedURL.path,
                requestedReportPath: arguments.reportURL.path,
                requestedDecodedDirectory: arguments.decodedDirectoryURL.path
            )
            let target = failureURL(for: arguments.reportURL)
            do {
                try writeNewJSON(failure, to: target)
                FileHandle.standardError.write(
                    Data("common writer failed; evidence preserved at \(target.path): \(error)\n".utf8)
                )
            } catch let preservationError {
                FileHandle.standardError.write(
                    Data("common writer failed: \(error); evidence error: \(preservationError)\n".utf8)
                )
            }
            exit(EXIT_FAILURE)
        }
    }
}
