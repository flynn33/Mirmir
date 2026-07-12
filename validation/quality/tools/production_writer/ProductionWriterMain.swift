import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation

private func waitForMirmirExecutionGate() throws {
    guard let raw = ProcessInfo.processInfo.environment["MIRMIR_EXECUTION_GATE_FD"] else {
        return
    }
    guard let descriptor = Int32(raw), descriptor >= 0 else {
        throw FixtureError.invalidArgument("execution gate descriptor is invalid")
    }
    var authorization: UInt8 = 0
    var count = -1
    repeat {
        count = withUnsafeMutableBytes(of: &authorization) { bytes in
            Darwin.read(descriptor, bytes.baseAddress, 1)
        }
    } while count < 0 && errno == EINTR
    Darwin.close(descriptor)
    guard count == 1, authorization == 0xA5 else {
        throw FixtureError.invalidArgument("execution gate authorization failed")
    }
}

private struct ProductionWriterDescriptors {
    let source: Int32
    let sourceLock: Int32
    let encoded: Int32
    let encodedStagingDirectory: Int32
    let report: Int32
    let failureReport: Int32
    let decodedDirectory: Int32
    let productSettingsSource: Int32

    var all: [Int32] {
        [
            source,
            sourceLock,
            encoded,
            encodedStagingDirectory,
            report,
            failureReport,
            decodedDirectory,
            productSettingsSource
        ]
    }
}

private struct ProductionWriterArguments {
    let sourceURL: URL
    let sourceLockURL: URL
    let encodedURL: URL
    let encodedStagingDirectoryURL: URL?
    let reportURL: URL
    let decodedDirectoryURL: URL
    let productSettingsSourceURL: URL
    let failureReportURL: URL?
    let descriptors: ProductionWriterDescriptors?

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
        let required = [
            "--source",
            "--source-lock",
            "--encoded",
            "--report",
            "--decoded-directory",
            "--product-settings-source"
        ]
        let descriptorKeys = [
            "--source-fd",
            "--source-lock-fd",
            "--encoded-fd",
            "--encoded-staging-directory-fd",
            "--report-fd",
            "--failure-report-fd",
            "--decoded-directory-fd",
            "--product-settings-source-fd"
        ]
        let descriptorMode = descriptorKeys.contains { options[$0] != nil }
        let requiredValues = required + (
            descriptorMode
                ? ["--failure-report", "--encoded-staging-directory"]
                : []
        )
        let missing = requiredValues.filter { options[$0] == nil }
        guard missing.isEmpty else {
            throw FixtureError.invalidArgument(
                "missing arguments: \(missing.joined(separator: ", "))"
            )
        }
        let allowed = Set(
            requiredValues + (descriptorMode ? descriptorKeys : [])
        )
        guard Set(options.keys) == allowed else {
            throw FixtureError.invalidArgument(
                "production writer argument set differs"
            )
        }
        sourceURL = URL(fileURLWithPath: options["--source"]!)
        sourceLockURL = URL(fileURLWithPath: options["--source-lock"]!)
        encodedURL = URL(fileURLWithPath: options["--encoded"]!)
        encodedStagingDirectoryURL = options["--encoded-staging-directory"].map {
            URL(fileURLWithPath: $0)
        }
        reportURL = URL(fileURLWithPath: options["--report"]!)
        decodedDirectoryURL = URL(fileURLWithPath: options["--decoded-directory"]!)
        productSettingsSourceURL = URL(
            fileURLWithPath: options["--product-settings-source"]!
        )
        failureReportURL = options["--failure-report"].map(URL.init(fileURLWithPath:))
        if descriptorMode {
            let missingDescriptors = descriptorKeys.filter { options[$0] == nil }
            guard missingDescriptors.isEmpty else {
                throw FixtureError.invalidArgument(
                    "missing descriptor arguments: \(missingDescriptors.joined(separator: ", "))"
                )
            }
            let parsed = descriptorKeys.map { Int32(options[$0]!) }
            guard parsed.allSatisfy({ $0 != nil && $0! >= 3 }) else {
                throw FixtureError.invalidArgument(
                    "writer descriptors must be inherited integers at least three"
                )
            }
            let values = parsed.map { $0! }
            guard Set(values).count == values.count else {
                throw FixtureError.invalidArgument("writer descriptors must be unique")
            }
            descriptors = ProductionWriterDescriptors(
                source: values[0],
                sourceLock: values[1],
                encoded: values[2],
                encodedStagingDirectory: values[3],
                report: values[4],
                failureReport: values[5],
                decodedDirectory: values[6],
                productSettingsSource: values[7]
            )
        } else {
            guard options["--failure-report"] == nil,
                  options["--encoded-staging-directory"] == nil,
                  descriptorKeys.allSatisfy({ options[$0] == nil }) else {
                throw FixtureError.invalidArgument(
                    "writer descriptor arguments must be all present or all absent"
                )
            }
            descriptors = nil
        }
    }

    func descriptorURL(_ descriptor: Int32) -> URL {
        URL(fileURLWithPath: "/dev/fd/\(descriptor)")
    }
}

private enum ProductionWriterDescriptorKind {
    case readOnlyRegular
    case readWriteEmptyRegular
    case directory
}

private func validatePinnedDescriptor(
    _ descriptor: Int32,
    path: URL,
    kind: ProductionWriterDescriptorKind
) throws {
    var opened = stat()
    var linked = stat()
    guard fstat(descriptor, &opened) == 0,
          path.path.withCString({ lstat($0, &linked) }) == 0,
          linked.st_mode & S_IFMT != S_IFLNK,
          opened.st_dev == linked.st_dev,
          opened.st_ino == linked.st_ino else {
        throw FixtureError.invalidArgument(
            "writer descriptor does not match its pinned path \(path.path)"
        )
    }
    let accessMode = fcntl(descriptor, F_GETFL) & O_ACCMODE
    switch kind {
    case .readOnlyRegular:
        guard opened.st_mode & S_IFMT == S_IFREG,
              opened.st_nlink == 1,
              accessMode == O_RDONLY || accessMode == O_RDWR else {
            throw FixtureError.invalidArgument(
                "writer input descriptor is not singular readable regular data"
            )
        }
    case .readWriteEmptyRegular:
        guard opened.st_mode & S_IFMT == S_IFREG,
              opened.st_nlink == 1,
              opened.st_size == 0,
              accessMode == O_RDWR else {
            throw FixtureError.invalidArgument(
                "writer output descriptor is not singular empty read-write data"
            )
        }
    case .directory:
        guard opened.st_mode & S_IFMT == S_IFDIR,
              accessMode == O_RDONLY else {
            throw FixtureError.invalidArgument(
                "writer decoded-directory descriptor is invalid"
            )
        }
    }
}

private func validateDescriptorEndpoints(
    _ arguments: ProductionWriterArguments
) throws {
    guard let descriptors = arguments.descriptors,
          let failureReportURL = arguments.failureReportURL,
          let encodedStagingDirectoryURL = arguments.encodedStagingDirectoryURL else {
        return
    }
    try validatePinnedDescriptor(
        descriptors.source,
        path: arguments.sourceURL,
        kind: .readOnlyRegular
    )
    try validatePinnedDescriptor(
        descriptors.sourceLock,
        path: arguments.sourceLockURL,
        kind: .readOnlyRegular
    )
    try validatePinnedDescriptor(
        descriptors.productSettingsSource,
        path: arguments.productSettingsSourceURL,
        kind: .readOnlyRegular
    )
    try validatePinnedDescriptor(
        descriptors.encoded,
        path: arguments.encodedURL,
        kind: .readWriteEmptyRegular
    )
    try validatePinnedDescriptor(
        descriptors.encodedStagingDirectory,
        path: encodedStagingDirectoryURL,
        kind: .directory
    )
    try validatePinnedDescriptor(
        descriptors.report,
        path: arguments.reportURL,
        kind: .readWriteEmptyRegular
    )
    try validatePinnedDescriptor(
        descriptors.failureReport,
        path: failureReportURL,
        kind: .readWriteEmptyRegular
    )
    try validatePinnedDescriptor(
        descriptors.decodedDirectory,
        path: arguments.decodedDirectoryURL,
        kind: .directory
    )
}

private func stableDescriptorData(_ descriptor: Int32) throws -> Data {
    var before = stat()
    guard fstat(descriptor, &before) == 0,
          before.st_mode & S_IFMT == S_IFREG,
          before.st_size >= 0,
          let size = Int(exactly: before.st_size),
          lseek(descriptor, 0, SEEK_SET) == 0 else {
        throw FixtureError.invalidArgument("writer descriptor cannot be read")
    }
    var data = Data(count: size)
    var offset = 0
    try data.withUnsafeMutableBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        while offset < size {
            let count = Darwin.read(
                descriptor,
                base.advanced(by: offset),
                size - offset
            )
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw FixtureError.invalidArgument(
                    "writer descriptor read made no progress"
                )
            }
            offset += count
        }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
          before.st_dev == after.st_dev,
          before.st_ino == after.st_ino,
          before.st_size == after.st_size,
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
          before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
          lseek(descriptor, 0, SEEK_SET) == 0 else {
        throw FixtureError.invalidArgument(
            "writer descriptor changed while reading"
        )
    }
    return data
}

private func writeDescriptorData(_ payload: Data, descriptor: Int32) throws {
    guard ftruncate(descriptor, 0) == 0,
          lseek(descriptor, 0, SEEK_SET) == 0 else {
        throw FixtureError.failed("writer descriptor could not be reset")
    }
    var offset = 0
    try payload.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        while offset < payload.count {
            let count = Darwin.write(
                descriptor,
                base.advanced(by: offset),
                payload.count - offset
            )
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw FixtureError.failed(
                    "writer descriptor write made no progress"
                )
            }
            offset += count
        }
    }
    guard fsync(descriptor) == 0,
          try stableDescriptorData(descriptor) == payload else {
        throw FixtureError.failed("writer descriptor persistence differs")
    }
}

private final class RetainedMP4ResourceLoader: NSObject,
    AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let descriptor: Int32
    private let size: Int64

    init(descriptor: Int32, size: Int64) {
        self.descriptor = descriptor
        self.size = size
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = AVFileType.mp4.rawValue
            information.contentLength = size
            information.isByteRangeAccessSupported = true
        }
        guard let request = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let start = max(request.currentOffset, request.requestedOffset)
        guard start >= 0, start <= size else {
            loadingRequest.finishLoading(with: NSError(
                domain: "MirmirRetainedMP4",
                code: 1
            ))
            return true
        }
        let requested: Int64
        if request.requestsAllDataToEndOfResource {
            requested = size - start
        } else {
            requested = min(Int64(request.requestedLength), size - start)
        }
        var offset = start
        var remaining = requested
        while remaining > 0 {
            if loadingRequest.isCancelled {
                return true
            }
            let count = Int(min(remaining, 1024 * 1024))
            var payload = Data(count: count)
            var completed = 0
            let succeeded = payload.withUnsafeMutableBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return count == 0 }
                while completed < count {
                    let result = pread(
                        descriptor,
                        base.advanced(by: completed),
                        count - completed,
                        offset + Int64(completed)
                    )
                    if result < 0 && errno == EINTR { continue }
                    guard result > 0 else { return false }
                    completed += result
                }
                return true
            }
            guard succeeded else {
                loadingRequest.finishLoading(with: NSError(
                    domain: "MirmirRetainedMP4",
                    code: 2
                ))
                return true
            }
            request.respond(with: payload)
            offset += Int64(count)
            remaining -= Int64(count)
        }
        loadingRequest.finishLoading()
        return true
    }
}

private func loadRetainedAssetDescriptor(
    descriptor: Int32
) async throws -> (AssetDescriptor, RetainedMP4ResourceLoader) {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          metadata.st_mode & S_IFMT == S_IFREG,
          metadata.st_nlink == 1,
          metadata.st_size > 0 else {
        throw FixtureError.invalidFixture("retained MP4 descriptor is invalid")
    }
    let loader = RetainedMP4ResourceLoader(
        descriptor: descriptor,
        size: metadata.st_size
    )
    let asset = AVURLAsset(
        url: URL(string: "mirmir-retained-mp4://asset/video.mp4")!,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    asset.resourceLoader.setDelegate(
        loader,
        queue: DispatchQueue(label: "mirmir.production-writer.retained-mp4")
    )
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard tracks.count == 1, let track = tracks.first else {
        throw FixtureError.invalidFixture(
            "retained MP4 must contain exactly one video track"
        )
    }
    let formats = try await track.load(.formatDescriptions)
    guard let format = formats.first else {
        throw FixtureError.invalidFixture(
            "retained MP4 video format description is absent"
        )
    }
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    return (
        AssetDescriptor(
            asset: asset,
            track: track,
            format: format,
            duration: try await asset.load(.duration),
            trackEnd: CMTimeRangeGetEnd(try await track.load(.timeRange)),
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            codec: fourCC(CMFormatDescriptionGetMediaSubType(format)),
            attachments: formatAttachments(format)
        ),
        loader
    )
}

private func validateOutputEndpoints(_ arguments: ProductionWriterArguments) throws {
    let manager = FileManager.default
    if arguments.descriptors == nil {
        for url in [arguments.encodedURL, arguments.reportURL, arguments.decodedDirectoryURL] {
            guard !manager.fileExists(atPath: url.path) else {
                throw FixtureError.invalidArgument(
                    "refusing to overwrite existing output \(url.path)"
                )
            }
        }
    }
    guard arguments.encodedURL.pathExtension.lowercased() == "mp4" else {
        throw FixtureError.invalidArgument("encoded output must use the .mp4 extension")
    }
    guard arguments.productSettingsSourceURL.lastPathComponent == "MediaTypes.swift" else {
        throw FixtureError.invalidArgument(
            "product settings source must be MediaTypes.swift"
        )
    }
    if arguments.descriptors == nil,
       !manager.isReadableFile(atPath: arguments.productSettingsSourceURL.path) {
        throw FixtureError.invalidArgument(
            "product settings source must be the readable MediaTypes.swift"
        )
    }
    try validateDescriptorEndpoints(arguments)
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
        throw FixtureError.invalidFixture(
            "source lock identity, layout, or frame count is invalid"
        )
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
        throw FixtureError.invalidFixture(
            "source NV12 payload size is inconsistent with geometry"
        )
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
            throw FixtureError.invalidFixture(
                "source frame \(position) identity or timing is invalid"
            )
        }
        if let previousPresentationTime,
           CMTimeCompare(presentationTime, previousPresentationTime) <= 0 {
            throw FixtureError.invalidFixture(
                "source presentation times are not strictly increasing"
            )
        }
        previousPresentationTime = presentationTime
        let offset = position * frameSize
        let framePayload = payload.subdata(in: offset..<(offset + frameSize))
        let luma = framePayload.subdata(in: 0..<lumaSize)
        let chroma = framePayload.subdata(in: lumaSize..<frameSize)
        let chromaBlue = Data(
            chroma.enumerated().compactMap {
                $0.offset.isMultiple(of: 2) ? $0.element : nil
            }
        )
        let chromaRed = Data(
            chroma.enumerated().compactMap {
                $0.offset.isMultiple(of: 2) ? nil : $0.element
            }
        )
        let hashes = PlaneHashes(
            luma: sha256(luma),
            chromaBlue: sha256(chromaBlue),
            chromaRed: sha256(chromaRed)
        )
        guard hashes == frame.activeRowSha256,
              sha256(framePayload) == frame.frameNv12Sha256 else {
            throw FixtureError.invalidFixture(
                "source frame \(position) hashes do not match"
            )
        }
    }
}

private func endpoint(_ source: CommonWriterSourceLock) throws -> CMTime {
    guard let final = source.frames.last else {
        throw FixtureError.invalidFixture("source lock has no frames")
    }
    return CMTimeAdd(final.presentationTime.cmTime, final.duration.cmTime)
}

private func copySourcePayload(
    _ payload: Data,
    offset: Int,
    width: Int,
    height: Int,
    pool: CVPixelBufferPool
) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let createStatus = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault,
        pool,
        &pixelBuffer
    )
    guard createStatus == kCVReturnSuccess, let pixelBuffer else {
        throw FixtureError.operation("CVPixelBufferPoolCreatePixelBuffer", createStatus)
    }
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == expectedPixelFormat,
          CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
        throw FixtureError.invalidFixture("production writer pool is not video-range NV12")
    }
    let frameSize = width * height * 3 / 2
    guard offset >= 0, offset + frameSize <= payload.count else {
        throw FixtureError.invalidFixture("source NV12 payload is truncated")
    }
    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard lockStatus == kCVReturnSuccess else {
        throw FixtureError.operation("CVPixelBufferLockBaseAddress", lockStatus)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
          let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
        throw FixtureError.invalidFixture("production writer plane base address is absent")
    }
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    payload.withUnsafeBytes { source in
        guard let sourceBase = source.baseAddress else { return }
        for row in 0..<height {
            memcpy(
                lumaBase.advanced(by: row * lumaStride),
                sourceBase.advanced(by: offset + row * width),
                width
            )
        }
        let chromaOffset = offset + width * height
        for row in 0..<(height / 2) {
            memcpy(
                chromaBase.advanced(by: row * chromaStride),
                sourceBase.advanced(by: chromaOffset + row * width),
                width
            )
        }
    }
    let attachments: [(CFString, CFString)] = [
        (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
        (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
        (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
        (kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left)
    ]
    for (key, value) in attachments {
        CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
    }
    return pixelBuffer
}

private struct ProductionWriterVnodeIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    let linkCount: UInt16

    init(_ metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        mode = UInt16(metadata.st_mode & S_IFMT)
        linkCount = UInt16(metadata.st_nlink)
    }
}

private struct ProductionWriterFrozenSnapshot: Equatable {
    let identity: ProductionWriterVnodeIdentity
    let permissions: UInt16
    let flags: UInt32
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ metadata: stat) {
        identity = ProductionWriterVnodeIdentity(metadata)
        permissions = UInt16(metadata.st_mode & 0o7777)
        flags = metadata.st_flags
        size = metadata.st_size
        modifiedSeconds = metadata.st_mtimespec.tv_sec
        modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
        changedSeconds = metadata.st_ctimespec.tv_sec
        changedNanoseconds = metadata.st_ctimespec.tv_nsec
    }
}

private func descriptorSnapshot(_ descriptor: Int32) throws
    -> ProductionWriterFrozenSnapshot {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
        throw FixtureError.failed("writer descriptor snapshot failed")
    }
    return ProductionWriterFrozenSnapshot(metadata)
}

private func directoryNames(_ descriptor: Int32) throws -> Set<String> {
    let duplicate = dup(descriptor)
    guard duplicate >= 0,
          lseek(duplicate, 0, SEEK_SET) == 0,
          let directory = fdopendir(duplicate) else {
        if duplicate >= 0 { Darwin.close(duplicate) }
        throw FixtureError.failed("writer staging directory cannot be enumerated")
    }
    defer { closedir(directory) }
    var names = Set<String>()
    while let entry = readdir(directory) {
        var rawName = entry.pointee.d_name
        let name = withUnsafePointer(to: &rawName) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
        if name != "." && name != ".." {
            names.insert(name)
        }
    }
    return names
}

private func processVnodeDescriptors(
    matching identity: ProductionWriterVnodeIdentity,
    expectedPath: String,
    excluding excluded: Set<Int32>,
    writableOnly: Bool
) throws -> Set<Int32> {
    let requiredBytes = proc_pidinfo(
        getpid(),
        PROC_PIDLISTFDS,
        0,
        nil,
        0
    )
    guard requiredBytes > 0 else {
        throw FixtureError.failed("writer process FD inventory is unavailable")
    }
    var records = [proc_fdinfo](
        repeating: proc_fdinfo(),
        count: Int(requiredBytes) / MemoryLayout<proc_fdinfo>.stride + 16
    )
    let populated = records.withUnsafeMutableBytes { bytes in
        proc_pidinfo(
            getpid(),
            PROC_PIDLISTFDS,
            0,
            bytes.baseAddress,
            Int32(bytes.count)
        )
    }
    guard populated >= 0 else {
        throw FixtureError.failed("writer process FD inventory failed")
    }
    var matches = Set<Int32>()
    for record in records.prefix(
        Int(populated) / MemoryLayout<proc_fdinfo>.stride
    ) where record.proc_fdtype == PROX_FDTYPE_VNODE
        && !excluded.contains(record.proc_fd) {
        var information = vnode_fdinfowithpath()
        let size = proc_pidfdinfo(
            getpid(),
            record.proc_fd,
            PROC_PIDFDVNODEPATHINFO,
            &information,
            Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        )
        guard size == MemoryLayout<vnode_fdinfowithpath>.size else { continue }
        let observed = information.pvip.vip_vi.vi_stat
        var rawPath = information.pvip.vip_path
        let observedPath = withUnsafePointer(to: &rawPath) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        if UInt64(observed.vst_dev) == identity.device,
           observed.vst_ino == identity.inode,
           UInt16(observed.vst_mode & UInt16(S_IFMT)) == identity.mode,
           observed.vst_nlink == identity.linkCount,
           observedPath == expectedPath,
           !writableOnly || information.pfi.fi_openflags & UInt32(FWRITE) != 0 {
            matches.insert(record.proc_fd)
        }
    }
    return matches
}

private func descriptorCanonicalPath(_ descriptor: Int32) throws -> String {
    var information = vnode_fdinfowithpath()
    let size = proc_pidfdinfo(
        getpid(),
        descriptor,
        PROC_PIDFDVNODEPATHINFO,
        &information,
        Int32(MemoryLayout<vnode_fdinfowithpath>.size)
    )
    guard size == MemoryLayout<vnode_fdinfowithpath>.size else {
        throw FixtureError.failed("writer descriptor canonical path is unavailable")
    }
    var rawPath = information.pvip.vip_path
    return withUnsafePointer(to: &rawPath) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
            String(cString: $0)
        }
    }
}

private func freezeWriterStagingDirectory(
    directoryDescriptor: Int32,
    outputName: String,
    inheritedDescriptors: Set<Int32>
) throws -> (ProductionWriterVnodeIdentity, ProductionWriterFrozenSnapshot) {
    guard try directoryNames(directoryDescriptor) == Set([outputName]) else {
        throw FixtureError.failed("writer staging directory contents differ")
    }
    let verifier = openat(
        directoryDescriptor,
        outputName,
        O_RDONLY | O_NOFOLLOW
    )
    guard verifier >= 0 else {
        throw FixtureError.failed("writer staging output cannot be retained")
    }
    defer { Darwin.close(verifier) }
    let fileSnapshot = try descriptorSnapshot(verifier)
    let canonicalOutputPath = try descriptorCanonicalPath(verifier)
    guard fileSnapshot.identity.mode == UInt16(S_IFREG),
          fileSnapshot.identity.linkCount == 1,
          try processVnodeDescriptors(
            matching: fileSnapshot.identity,
            expectedPath: canonicalOutputPath,
            excluding: inheritedDescriptors.union([verifier]),
            writableOnly: true
          ).count == 1,
          fchmod(verifier, 0o400) == 0,
          try descriptorSnapshot(verifier).permissions == 0o400 else {
        throw FixtureError.failed(
            "AVAssetWriter does not hold the exact staging vnode"
        )
    }
    let beforeFreeze = try descriptorSnapshot(directoryDescriptor)
    guard beforeFreeze.identity.mode == UInt16(S_IFDIR),
          beforeFreeze.flags & UInt32(UF_IMMUTABLE) == 0,
          fchmod(directoryDescriptor, 0o500) == 0,
          fchflags(directoryDescriptor, beforeFreeze.flags | UInt32(UF_IMMUTABLE)) == 0 else {
        throw FixtureError.failed("writer staging directory could not be frozen")
    }
    let frozen = try descriptorSnapshot(directoryDescriptor)
    guard frozen.identity == beforeFreeze.identity,
          frozen.permissions == 0o500,
          frozen.flags & UInt32(UF_IMMUTABLE) != 0,
          try directoryNames(directoryDescriptor) == Set([outputName]) else {
        throw FixtureError.failed("writer staging directory freeze differs")
    }
    let reopened = openat(
        directoryDescriptor,
        outputName,
        O_RDONLY | O_NOFOLLOW
    )
    guard reopened >= 0 else {
        throw FixtureError.failed("frozen writer output cannot be reopened")
    }
    defer { Darwin.close(reopened) }
    guard try descriptorSnapshot(reopened).identity == fileSnapshot.identity,
          try processVnodeDescriptors(
            matching: fileSnapshot.identity,
            expectedPath: canonicalOutputPath,
            excluding: inheritedDescriptors.union([verifier, reopened]),
            writableOnly: true
          ).count == 1 else {
        throw FixtureError.failed("frozen writer output identity differs")
    }
    return (fileSnapshot.identity, frozen)
}

private func cleanupWriterStagingDirectory(
    directoryDescriptor: Int32,
    outputName: String
) {
    let output = openat(
        directoryDescriptor,
        outputName,
        O_RDONLY | O_NOFOLLOW
    )
    if output >= 0 {
        var metadata = stat()
        if fstat(output, &metadata) == 0 {
            _ = fchflags(output, metadata.st_flags & ~UInt32(UF_IMMUTABLE))
            _ = fchmod(output, 0o600)
        }
        Darwin.close(output)
    }
    var directoryMetadata = stat()
    if fstat(directoryDescriptor, &directoryMetadata) == 0 {
        _ = fchflags(
            directoryDescriptor,
            directoryMetadata.st_flags & ~UInt32(UF_IMMUTABLE)
        )
        _ = fchmod(directoryDescriptor, 0o700)
    }
    _ = unlinkat(directoryDescriptor, outputName, 0)
}

private func thawWriterOutput(_ descriptor: Int32) {
    var metadata = stat()
    if fstat(descriptor, &metadata) == 0 {
        _ = fchflags(descriptor, metadata.st_flags & ~UInt32(UF_IMMUTABLE))
        _ = fchmod(descriptor, 0o600)
    }
}

private struct ProductionWriterEncodeOutcome {
    let requestedBitRate: Int
    let stagingFileSnapshot: ProductionWriterFrozenSnapshot?
    let stagingDirectorySnapshot: ProductionWriterFrozenSnapshot?
}

private func encodeWithProductWriter(
    sourcePayload: Data,
    source: CommonWriterSourceLock,
    outputURL: URL,
    stagingDirectoryDescriptor: Int32?,
    inheritedDescriptors: Set<Int32>
) async throws -> ProductionWriterEncodeOutcome {
    let width = source.pixelLayout.width
    let height = source.pixelLayout.height
    let resolution = VideoResolution(width: width, height: height)
    let outputSettings = ProductVideoOutputSettings.make(
        resolution: resolution,
        codec: .hevc
    )
    let requestedBitRate = ProductVideoOutputSettings.estimatedBitRate(
        width: width,
        height: height,
        codec: .hevc
    )
    let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    input.expectsMediaDataInRealTime = false
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: expectedPixelFormat),
        kCVPixelBufferWidthKey as String: NSNumber(value: width),
        kCVPixelBufferHeightKey as String: NSNumber(value: height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: attributes
    )
    guard writer.canAdd(input) else {
        throw FixtureError.failed("AVAssetWriter rejected the product video input")
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw FixtureError.failed(
            "AVAssetWriter start failed: \(String(describing: writer.error))"
        )
    }
    let frozenStaging: (
        ProductionWriterVnodeIdentity,
        ProductionWriterFrozenSnapshot
    )?
    if let stagingDirectoryDescriptor {
        frozenStaging = try freezeWriterStagingDirectory(
            directoryDescriptor: stagingDirectoryDescriptor,
            outputName: outputURL.lastPathComponent,
            inheritedDescriptors: inheritedDescriptors
        )
    } else {
        frozenStaging = nil
    }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else {
        writer.cancelWriting()
        throw FixtureError.failed("AVAssetWriter adaptor pixel-buffer pool is absent")
    }
    let frameSize = width * height * 3 / 2
    for frame in source.frames {
        let deadline = Date().addingTimeInterval(30)
        while !input.isReadyForMoreMediaData {
            if Date() >= deadline {
                writer.cancelWriting()
                throw FixtureError.failed("AVAssetWriter input readiness timed out")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let pixelBuffer = try copySourcePayload(
            sourcePayload,
            offset: frame.index * frameSize,
            width: width,
            height: height,
            pool: pool
        )
        guard adaptor.append(
            pixelBuffer,
            withPresentationTime: frame.presentationTime.cmTime
        ) else {
            writer.cancelWriting()
            throw FixtureError.failed(
                "AVAssetWriter append failed: \(String(describing: writer.error))"
            )
        }
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: try endpoint(source))
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw FixtureError.failed(
            "AVAssetWriter finish failed: \(String(describing: writer.error))"
        )
    }
    if let stagingDirectoryDescriptor,
       let (expectedIdentity, expectedDirectory) = frozenStaging {
        guard try descriptorSnapshot(stagingDirectoryDescriptor)
                == expectedDirectory,
              try directoryNames(stagingDirectoryDescriptor)
                == Set([outputURL.lastPathComponent]) else {
            throw FixtureError.failed(
                "writer staging directory changed during encoding"
            )
        }
        let output = openat(
            stagingDirectoryDescriptor,
            outputURL.lastPathComponent,
            O_RDONLY | O_NOFOLLOW
        )
        guard output >= 0 else {
            throw FixtureError.failed("completed writer output cannot be retained")
        }
        defer { Darwin.close(output) }
        let beforeFileFreeze = try descriptorSnapshot(output)
        guard beforeFileFreeze.identity == expectedIdentity,
              beforeFileFreeze.size > 0,
              fchmod(output, 0o400) == 0,
              fchflags(
                output,
                beforeFileFreeze.flags | UInt32(UF_IMMUTABLE)
              ) == 0 else {
            throw FixtureError.failed("completed writer output could not be frozen")
        }
        let frozenFile = try descriptorSnapshot(output)
        guard frozenFile.identity == expectedIdentity,
              frozenFile.permissions == 0o400,
              frozenFile.flags & UInt32(UF_IMMUTABLE) != 0 else {
            throw FixtureError.failed("completed writer output freeze differs")
        }
        return ProductionWriterEncodeOutcome(
            requestedBitRate: requestedBitRate,
            stagingFileSnapshot: frozenFile,
            stagingDirectorySnapshot: expectedDirectory
        )
    }
    return ProductionWriterEncodeOutcome(
        requestedBitRate: requestedBitRate,
        stagingFileSnapshot: nil,
        stagingDirectorySnapshot: nil
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
    var payload = Data()
    payload.reserveCapacity(width * height * 3 / 2)
    for row in 0..<height {
        payload.append(
            Data(bytes: lumaBase.advanced(by: row * lumaStride), count: width)
        )
    }
    for row in 0..<(height / 2) {
        payload.append(
            Data(bytes: chromaBase.advanced(by: row * chromaStride), count: width)
        )
    }
    return payload
}

private func attachmentsAreRecorded(_ value: AttachmentEvidence) -> Bool {
    value.colorPrimaries != nil
        && value.transferFunction != nil
        && value.yCbCrMatrix != nil
        && value.chromaLocationTopField != nil
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
            throw FixtureError.invalidFixture(
                "decoded frame \(index) timing differs from its source lock"
            )
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
              attachmentsAreRecorded(frameEvidence.attachments) else {
            throw FixtureError.invalidFixture(
                "decoded frame \(index) format evidence is incomplete"
            )
        }
        let lumaSize = frameEvidence.width * frameEvidence.height
        let luma = payload.subdata(in: 0..<lumaSize)
        let chroma = payload.subdata(in: lumaSize..<payload.count)
        let hashes = PlaneHashes(
            luma: sha256(luma),
            chromaBlue: sha256(
                Data(
                    chroma.enumerated().compactMap {
                        $0.offset.isMultiple(of: 2) ? $0.element : nil
                    }
                )
            ),
            chromaRed: sha256(
                Data(
                    chroma.enumerated().compactMap {
                        $0.offset.isMultiple(of: 2) ? nil : $0.element
                    }
                )
            )
        )
        guard hashes == frameEvidence.activeRowSha256 else {
            throw FixtureError.invalidFixture(
                "decoded frame \(index) payload hashes are inconsistent"
            )
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

private func writeNewJSON<T: Encodable>(_ value: T, to url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw FixtureError.invalidArgument(
            "refusing to overwrite existing JSON \(url.path)"
        )
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

private func writeJSON<T: Encodable>(
    _ value: T,
    to url: URL,
    descriptor: Int32?
) throws {
    if let descriptor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeDescriptorData(
            try encoder.encode(value) + Data([0x0a]),
            descriptor: descriptor
        )
    } else {
        try writeNewJSON(value, to: url)
    }
}

private func failureURL(for reportURL: URL) -> URL {
    let directory = reportURL.deletingLastPathComponent()
    let stem = reportURL.deletingPathExtension().lastPathComponent
    for index in 1...9999 {
        let candidate = directory.appendingPathComponent(
            "\(stem).failed-\(index).json"
        )
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
    }
    return directory.appendingPathComponent("\(stem).failed-overflow.json")
}

private func exportDecodedPayloads(
    _ frames: [(CommonWriterDecodedFrame, Data)],
    to directory: URL,
    descriptor: Int32?
) throws {
    if descriptor == nil {
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw FixtureError.invalidArgument(
                "refusing to overwrite decoded directory \(directory.path)"
            )
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }
    for (frame, payload) in frames {
        let persisted: Data
        if let descriptor {
            guard !frame.payloadPath.isEmpty,
                  URL(fileURLWithPath: frame.payloadPath).lastPathComponent
                    == frame.payloadPath else {
                throw FixtureError.invalidFixture(
                    "decoded payload path is not a filename"
                )
            }
            let payloadDescriptor = openat(
                descriptor,
                frame.payloadPath,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW,
                0o600
            )
            guard payloadDescriptor >= 0 else {
                throw FixtureError.failed(
                    "decoded payload descriptor could not be created"
                )
            }
            defer { Darwin.close(payloadDescriptor) }
            try writeDescriptorData(payload, descriptor: payloadDescriptor)
            persisted = try stableDescriptorData(payloadDescriptor)
        } else {
            let target = directory.appendingPathComponent(frame.payloadPath)
            try payload.write(to: target, options: .withoutOverwriting)
            persisted = try Data(contentsOf: target)
        }
        guard persisted.count == frame.payloadSizeBytes,
              sha256(persisted) == frame.payloadSha256 else {
            throw FixtureError.failed(
                "decoded frame \(frame.index) persistence verification failed"
            )
        }
    }
    if let descriptor, fsync(descriptor) != 0 {
        throw FixtureError.failed("decoded directory could not be synchronized")
    }
}

private func run(_ arguments: ProductionWriterArguments) async throws {
    try validateOutputEndpoints(arguments)
    let secureDescriptors = arguments.descriptors
    let stagingOutputName = "encoded.partial.mp4"
    defer {
        if let secureDescriptors {
            thawWriterOutput(secureDescriptors.encoded)
            cleanupWriterStagingDirectory(
                directoryDescriptor: secureDescriptors.encodedStagingDirectory,
                outputName: stagingOutputName
            )
        }
    }
    let sourcePayload = try arguments.descriptors.map {
        try stableDescriptorData($0.source)
    } ?? Data(contentsOf: arguments.sourceURL)
    let sourceLockData = try arguments.descriptors.map {
        try stableDescriptorData($0.sourceLock)
    } ?? Data(contentsOf: arguments.sourceLockURL)
    let sourceLock = try JSONDecoder().decode(
        CommonWriterSourceLock.self,
        from: sourceLockData
    )
    try validateSource(
        payload: sourcePayload,
        sourceURL: arguments.sourceURL,
        lock: sourceLock
    )
    let settingsSourceData = try arguments.descriptors.map {
        try stableDescriptorData($0.productSettingsSource)
    } ?? Data(contentsOf: arguments.productSettingsSourceURL)
    let writerOutputURL = arguments.encodedStagingDirectoryURL?.appendingPathComponent(
        stagingOutputName
    ) ?? arguments.encodedURL
    let encodeOutcome = try await encodeWithProductWriter(
        sourcePayload: sourcePayload,
        source: sourceLock,
        outputURL: writerOutputURL,
        stagingDirectoryDescriptor: secureDescriptors?.encodedStagingDirectory,
        inheritedDescriptors: Set(secureDescriptors?.all ?? [])
    )
    let encodedPayload: Data
    let assetDescriptor: AssetDescriptor
    let retainedLoader: RetainedMP4ResourceLoader?
    let secureSnapshots: (
        final: ProductionWriterFrozenSnapshot,
        stagingFile: ProductionWriterFrozenSnapshot,
        stagingDirectory: ProductionWriterFrozenSnapshot
    )?
    if let secureDescriptors,
       let expectedStagingFile = encodeOutcome.stagingFileSnapshot,
       let expectedStagingDirectory = encodeOutcome.stagingDirectorySnapshot {
        let staging = openat(
            secureDescriptors.encodedStagingDirectory,
            stagingOutputName,
            O_RDONLY | O_NOFOLLOW
        )
        guard staging >= 0 else {
            throw FixtureError.failed("frozen staging output cannot be retained")
        }
        defer { Darwin.close(staging) }
        guard try descriptorSnapshot(staging) == expectedStagingFile,
              try descriptorSnapshot(secureDescriptors.encodedStagingDirectory)
                == expectedStagingDirectory else {
            throw FixtureError.failed("frozen staging output changed before copy")
        }
        encodedPayload = try stableDescriptorData(staging)
        try writeDescriptorData(
            encodedPayload,
            descriptor: secureDescriptors.encoded
        )
        let beforeFinalFreeze = try descriptorSnapshot(secureDescriptors.encoded)
        guard beforeFinalFreeze.identity.mode == UInt16(S_IFREG),
              beforeFinalFreeze.identity.linkCount == 1,
              beforeFinalFreeze.size == encodedPayload.count,
              fchmod(secureDescriptors.encoded, 0o400) == 0,
              fchflags(
                secureDescriptors.encoded,
                beforeFinalFreeze.flags | UInt32(UF_IMMUTABLE)
              ) == 0 else {
            throw FixtureError.failed("published encoded output could not be frozen")
        }
        let frozenFinal = try descriptorSnapshot(secureDescriptors.encoded)
        guard frozenFinal.permissions == 0o400,
              frozenFinal.flags & UInt32(UF_IMMUTABLE) != 0,
              try stableDescriptorData(secureDescriptors.encoded)
                == encodedPayload else {
            throw FixtureError.failed("published encoded output freeze differs")
        }
        let loaded = try await loadRetainedAssetDescriptor(
            descriptor: secureDescriptors.encoded
        )
        assetDescriptor = loaded.0
        retainedLoader = loaded.1
        secureSnapshots = (
            frozenFinal,
            expectedStagingFile,
            expectedStagingDirectory
        )
    } else if secureDescriptors == nil {
        encodedPayload = try Data(contentsOf: arguments.encodedURL)
        assetDescriptor = try await loadAssetDescriptor(url: arguments.encodedURL)
        retainedLoader = nil
        secureSnapshots = nil
    } else {
        throw FixtureError.failed("secure writer staging evidence is absent")
    }
    guard ["hvc1", "hev1"].contains(assetDescriptor.codec),
          assetDescriptor.width == sourceLock.pixelLayout.width,
          assetDescriptor.height == sourceLock.pixelLayout.height,
          CMTimeCompare(assetDescriptor.duration, try endpoint(sourceLock)) == 0,
          attachmentsAreRecorded(assetDescriptor.attachments) else {
        throw FixtureError.invalidFixture(
            "reopened production HEVC container evidence is inconsistent"
        )
    }
    let decoded = try decodedFrames(descriptor: assetDescriptor, source: sourceLock)
    _ = retainedLoader
    try exportDecodedPayloads(
        decoded,
        to: arguments.decodedDirectoryURL,
        descriptor: arguments.descriptors?.decodedDirectory
    )
    let estimatedDataRate = Double(
        try await assetDescriptor.track.load(.estimatedDataRate)
    )
    guard estimatedDataRate.isFinite, estimatedDataRate > 0 else {
        throw FixtureError.invalidFixture("reopened estimated data rate is not positive")
    }
    let report = ProductionWriterReport(
        schemaVersion: "1.0.0",
        artifactKind: "production_writer_actual_codec",
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
            codec: assetDescriptor.codec,
            width: assetDescriptor.width,
            height: assetDescriptor.height,
            frameCount: sourceLock.frameCount,
            duration: ExactTime(assetDescriptor.duration),
            formatAttachments: assetDescriptor.attachments
        ),
        encoder: ProductionWriterEncoderEvidence(
            framework: "AVFoundation",
            sessionType: "AVAssetWriterInput",
            requestedCodec: "hevc",
            reopenedCodec: assetDescriptor.codec,
            requestedAverageBitRate: encodeOutcome.requestedBitRate,
            observedEstimatedDataRate: estimatedDataRate,
            expectedFrameRate: ProductVideoOutputSettings.expectedFrameRate,
            expectsMediaDataInRealTime: false,
            pixelFormat: "420v",
            colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
            transferFunction: AVVideoTransferFunction_ITU_R_709_2,
            yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
            productSettingsSource: ProductionWriterSourceBinding(
                path: arguments.productSettingsSourceURL.lastPathComponent,
                sha256: sha256(settingsSourceData),
                sizeBytes: settingsSourceData.count
            )
        ),
        decoder: CommonWriterDecoderEvidence(
            framework: "AVFoundation",
            sessionType: "AVAssetReaderTrackOutput",
            codec: assetDescriptor.codec,
            pixelFormat: "420v",
            payloadLayout: "active_row_nv12_without_padding",
            frameCount: decoded.count,
            frames: decoded.map(\.0)
        ),
        containerScope: ProductionWriterContainerScope(
            frameCount: sourceLock.frameCount,
            singleFrameContainer: sourceLock.frameCount == 1,
            neighborFramesPresent: sourceLock.frameCount > 1,
            metricRole: sourceLock.frameCount == 1
                ? "isolated_metric_case"
                : "non_metric_smoke_only"
        ),
        verification: ProductionWriterVerification(
            sourceLockValid: true,
            sourceBytesMatchLock: true,
            productSettingsSourceBound: true,
            encodedContainerReopened: true,
            productionHEVCContainerUsed: true,
            exactCaseOrderPreserved: decoded.map(\.0.caseId)
                == sourceLock.frames.map(\.caseId),
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
            decodedPixelRepeatabilityScope: "no cross-run decoded-pixel identity is claimed for the production writer",
            decoderAccelerationVisibility: "AVAssetReaderTrackOutput does not expose decoder selection or acceleration state"
        )
    )
    guard report.verification.exactCaseOrderPreserved,
          report.verification.frameCountPreserved else {
        throw FixtureError.failed("post-decode order or frame-count verification failed")
    }
    try writeJSON(
        report,
        to: arguments.reportURL,
        descriptor: arguments.descriptors?.report
    )
    if let secureDescriptors, let secureSnapshots {
        let staging = openat(
            secureDescriptors.encodedStagingDirectory,
            stagingOutputName,
            O_RDONLY | O_NOFOLLOW
        )
        guard staging >= 0 else {
            throw FixtureError.failed(
                "frozen staging output cannot be reverified"
            )
        }
        defer { Darwin.close(staging) }
        guard try descriptorSnapshot(secureDescriptors.encoded)
                == secureSnapshots.final,
              try descriptorSnapshot(staging) == secureSnapshots.stagingFile,
              try descriptorSnapshot(secureDescriptors.encodedStagingDirectory)
                == secureSnapshots.stagingDirectory,
              try stableDescriptorData(secureDescriptors.encoded) == encodedPayload,
              try stableDescriptorData(secureDescriptors.source) == sourcePayload,
              try stableDescriptorData(secureDescriptors.sourceLock) == sourceLockData,
              try stableDescriptorData(secureDescriptors.productSettingsSource)
                == settingsSourceData else {
            throw FixtureError.failed(
                "secure writer descriptors changed before completion"
            )
        }
    }
    print("production writer verification passed: \(report.encoded.sha256)")
}

@main
struct ProductionWriterMain {
    static func main() async {
        let arguments: ProductionWriterArguments
        do {
            try waitForMirmirExecutionGate()
            _ = Darwin.umask(0o077)
            arguments = try ProductionWriterArguments(
                Array(CommandLine.arguments.dropFirst())
            )
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
            let target = arguments.failureReportURL
                ?? failureURL(for: arguments.reportURL)
            do {
                try writeJSON(
                    failure,
                    to: target,
                    descriptor: arguments.descriptors?.failureReport
                )
                FileHandle.standardError.write(
                    Data(
                        "production writer failed; evidence preserved at \(target.path): \(error)\n".utf8
                    )
                )
            } catch let preservationError {
                FileHandle.standardError.write(
                    Data(
                        "production writer failed: \(error); evidence error: \(preservationError)\n".utf8
                    )
                )
            }
            exit(EXIT_FAILURE)
        }
    }
}
