import AVFoundation
import CoreVideo
import CryptoKit
import Darwin
import Foundation

private func waitForMirmirExecutionGate() throws {
    guard let raw = ProcessInfo.processInfo.environment["MIRMIR_EXECUTION_GATE_FD"] else {
        return
    }
    guard let descriptor = Int32(raw), descriptor >= 0 else {
        throw P07LoaderError.invalidArguments
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
        throw P07LoaderError.invalidArguments
    }
}

private enum P07LoaderError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidPlan(String)
    case unsafePath(String)
    case fileRead(String)
    case fileWrite(String)
    case media(String)
    case output(String)

    var description: String {
        switch self {
        case .invalidArguments: return "invalid command arguments"
        case .invalidPlan(let value): return "invalid sampling plan: \(value)"
        case .unsafePath(let value): return "unsafe path: \(value)"
        case .fileRead(let value): return "file read failed: \(value)"
        case .fileWrite(let value): return "file write failed: \(value)"
        case .media(let value): return "media validation failed: \(value)"
        case .output(let value): return "output validation failed: \(value)"
        }
    }
}

private struct P07FrameRange: Decodable {
    let start: Int64
    let duration: Int64
    let timescale: Int32
}

private struct P07Dimensions: Decodable, Equatable {
    let width: Int
    let height: Int
}

private struct P07Crop: Decodable, Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

private struct P07ExpectedMetadata: Decodable {
    let pixelFormat: String
    let range: String
    let colorPrimaries: String
    let transferFunction: String
    let ycbcrMatrix: String
    let chromaLocation: String

    enum CodingKeys: String, CodingKey {
        case pixelFormat = "pixel_format"
        case range
        case colorPrimaries = "color_primaries"
        case transferFunction = "transfer_function"
        case ycbcrMatrix = "ycbcr_matrix"
        case chromaLocation = "chroma_location"
    }
}

private struct P07AssetPlan: Decodable {
    let ordinal: Int
    let assetID: String
    let sourceAssetID: String
    let sourceFamilyID: String
    let sourceSHA256: String
    let sourceSizeBytes: Int64
    let presentationDimensions: P07Dimensions
    let frameCount: Int
    let frameRange: P07FrameRange
    let targetRoute: String
    let crop: P07Crop
    let expectedMetadata: P07ExpectedMetadata

    enum CodingKeys: String, CodingKey {
        case ordinal
        case assetID = "asset_id"
        case sourceAssetID = "source_asset_id"
        case sourceFamilyID = "source_family_id"
        case sourceSHA256 = "source_sha256"
        case sourceSizeBytes = "source_size_bytes"
        case presentationDimensions = "presentation_dimensions"
        case frameCount = "frame_count"
        case frameRange = "frame_range"
        case targetRoute = "target_route"
        case crop
        case expectedMetadata = "expected_metadata"
    }
}

private struct P07SamplingPlan: Decodable {
    let schemaVersion: String
    let artifactKind: String
    let status: String
    let corpusManifestSHA256: String
    let assets: [P07AssetPlan]
    let targetPixelHashesKnownBeforeP07: Bool
    let holdoutAccessed: Bool
    let manifestSHA256: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case artifactKind = "artifact_kind"
        case status
        case corpusManifestSHA256 = "corpus_manifest_sha256"
        case assets
        case targetPixelHashesKnownBeforeP07 = "target_pixel_hashes_known_before_p07"
        case holdoutAccessed = "holdout_accessed"
        case manifestSHA256 = "manifest_sha256"
    }
}

private struct P07Options {
    private let values: [String: String]

    init(_ arguments: ArraySlice<String>) throws {
        guard arguments.count.isMultiple(of: 2) else {
            throw P07LoaderError.invalidArguments
        }
        var parsed: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let name = arguments[index]
            let valueIndex = arguments.index(after: index)
            guard name.hasPrefix("--"), parsed[name] == nil else {
                throw P07LoaderError.invalidArguments
            }
            parsed[name] = arguments[valueIndex]
            index = arguments.index(after: valueIndex)
        }
        values = parsed
    }

    func require(_ names: Set<String>) throws -> [String: String] {
        guard Set(values.keys) == names else {
            throw P07LoaderError.invalidArguments
        }
        return values
    }
}

private struct P07FileDigest {
    let sha256: String
    let sizeBytes: Int64
}

private enum P07FileIO {
    static func validateAbsolutePath(
        _ path: String,
        finalMustBeDirectory: Bool
    ) throws {
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("//"),
              !(path as NSString).pathComponents.contains("."),
              !(path as NSString).pathComponents.contains("..") else {
            throw P07LoaderError.unsafePath(path)
        }
        let components = (path as NSString).pathComponents
        var cursor = "/"
        for (offset, component) in components.dropFirst().enumerated() {
            cursor = (cursor as NSString).appendingPathComponent(component)
            var metadata = stat()
            guard lstat(cursor, &metadata) == 0,
                  metadata.st_mode & S_IFMT != S_IFLNK else {
                throw P07LoaderError.unsafePath(cursor)
            }
            let final = offset == components.count - 2
            if !final || finalMustBeDirectory {
                guard metadata.st_mode & S_IFMT == S_IFDIR else {
                    throw P07LoaderError.unsafePath(cursor)
                }
            } else {
                guard metadata.st_mode & S_IFMT == S_IFREG else {
                    throw P07LoaderError.unsafePath(cursor)
                }
            }
        }
    }

    static func digest(_ path: String) throws -> P07FileDigest {
        try validateAbsolutePath(path, finalMustBeDirectory: false)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw P07LoaderError.fileRead(path) }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0 else {
            throw P07LoaderError.fileRead(path)
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw P07LoaderError.fileRead(path) }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw P07LoaderError.fileRead("changed while hashing \(path)")
        }
        return P07FileDigest(
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            sizeBytes: before.st_size
        )
    }

    static func digestMountedRelative(_ path: String) throws -> P07FileDigest {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\\") else {
            throw P07LoaderError.unsafePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw P07LoaderError.unsafePath(path)
        }
        var cursor = ""
        for (index, component) in components.enumerated() {
            cursor = cursor.isEmpty ? String(component) : "\(cursor)/\(component)"
            var metadata = stat()
            guard lstat(cursor, &metadata) == 0,
                  metadata.st_mode & S_IFMT != S_IFLNK,
                  (index == components.count - 1
                    ? metadata.st_mode & S_IFMT == S_IFREG
                    : metadata.st_mode & S_IFMT == S_IFDIR) else {
                throw P07LoaderError.unsafePath(cursor)
            }
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw P07LoaderError.fileRead(path) }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size > 0 else {
            throw P07LoaderError.fileRead(path)
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            var count = -1
            repeat {
                count = Darwin.read(descriptor, &buffer, buffer.count)
            } while count < 0 && errno == EINTR
            guard count >= 0 else { throw P07LoaderError.fileRead(path) }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_nlink == before.st_nlink,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw P07LoaderError.fileRead("changed mounted \(path)")
        }
        return P07FileDigest(
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            sizeBytes: before.st_size
        )
    }

    static func read(_ path: String) throws -> Data {
        let expected = try digest(path)
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        } catch {
            throw P07LoaderError.fileRead(path)
        }
        guard Int64(data.count) == expected.sizeBytes,
              sha256(data) == expected.sha256 else {
            throw P07LoaderError.fileRead("changed while reopening \(path)")
        }
        return data
    }

    static func readRetainedDescriptor(
        _ raw: String,
        label: String
    ) throws -> (Data, P07FileDigest) {
        guard let descriptor = Int32(raw), descriptor >= 0 else {
            throw P07LoaderError.fileRead(label)
        }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size > 0,
              before.st_size <= 16 * 1024 * 1024,
              lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw P07LoaderError.fileRead(label)
        }
        var payload = Data()
        payload.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            var count = -1
            repeat {
                count = Darwin.read(descriptor, &buffer, buffer.count)
            } while count < 0 && errno == EINTR
            guard count >= 0 else { throw P07LoaderError.fileRead(label) }
            if count == 0 { break }
            payload.append(contentsOf: buffer[0..<count])
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_nlink == before.st_nlink,
              after.st_mode == before.st_mode,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              Int64(payload.count) == before.st_size else {
            throw P07LoaderError.fileRead("changed retained \(label)")
        }
        return (
            payload,
            P07FileDigest(
                sha256: sha256(payload),
                sizeBytes: before.st_size
            )
        )
    }

    static func retainedDirectoryDescriptor(
        _ raw: String,
        label: String
    ) throws -> Int32 {
        guard let descriptor = Int32(raw), descriptor >= 0 else {
            throw P07LoaderError.fileWrite(label)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            throw P07LoaderError.fileWrite(label)
        }
        return descriptor
    }

    static func validateOutputName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains("\0") else {
            throw P07LoaderError.fileWrite("unsafe output name")
        }
    }

    static func writeNewAt(
        _ data: Data,
        directoryDescriptor: Int32,
        name: String
    ) throws {
        try validateOutputName(name)
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { throw P07LoaderError.fileWrite(name) }
        var complete = false
        defer {
            close(descriptor)
            if !complete { unlinkat(directoryDescriptor, name, 0) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                var count = -1
                repeat {
                    count = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        data.count - offset
                    )
                } while count < 0 && errno == EINTR
                guard count > 0 else { throw P07LoaderError.fileWrite(name) }
                offset += count
            }
        }
        var metadata = stat()
        guard fsync(descriptor) == 0,
              fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size == Int64(data.count) else {
            throw P07LoaderError.fileWrite(name)
        }
        complete = true
    }

    static func digestAt(
        directoryDescriptor: Int32,
        name: String
    ) throws -> P07FileDigest {
        try validateOutputName(name)
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw P07LoaderError.fileRead(name) }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size > 0 else {
            throw P07LoaderError.fileRead(name)
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            var count = -1
            repeat {
                count = Darwin.read(descriptor, &buffer, buffer.count)
            } while count < 0 && errno == EINTR
            guard count >= 0 else { throw P07LoaderError.fileRead(name) }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_nlink == before.st_nlink,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw P07LoaderError.fileRead("changed output \(name)")
        }
        return P07FileDigest(
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            sizeBytes: before.st_size
        )
    }

    static func writeNew(_ data: Data, path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try validateAbsolutePath(parent, finalMustBeDirectory: true)
        guard !FileManager.default.fileExists(atPath: path) else {
            throw P07LoaderError.fileWrite("output exists: \(path)")
        }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw P07LoaderError.fileWrite(path) }
        var complete = false
        defer {
            close(descriptor)
            if !complete { unlink(path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                guard count > 0 else { throw P07LoaderError.fileWrite(path) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw P07LoaderError.fileWrite(path) }
        complete = true
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private func canonicalJSON(_ object: Any) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else {
        throw P07LoaderError.output("invalid JSON object")
    }
    return try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
}

private func validatedPlan(_ data: Data) throws -> P07SamplingPlan {
    let plan: P07SamplingPlan
    do {
        plan = try JSONDecoder().decode(P07SamplingPlan.self, from: data)
    } catch {
        throw P07LoaderError.invalidPlan("decode")
    }
    guard plan.schemaVersion == "1.0.0",
          plan.artifactKind == "p07_holdout_sampling_plan",
          plan.status == "preregistered_before_p06_no_pixel_access",
          plan.targetPixelHashesKnownBeforeP07 == false,
          plan.holdoutAccessed == false,
          plan.assets.count == 3,
          plan.assets.map(\.ordinal) == [0, 1, 2] else {
        throw P07LoaderError.invalidPlan("identity or cardinality")
    }
    let object = try JSONSerialization.jsonObject(with: data)
    guard var dictionary = object as? [String: Any],
          dictionary.removeValue(forKey: "manifest_sha256") as? String
            == plan.manifestSHA256,
          P07FileIO.sha256(try canonicalJSON(dictionary)) == plan.manifestSHA256 else {
        throw P07LoaderError.invalidPlan("self hash")
    }
    for asset in plan.assets {
        let dimensions = asset.presentationDimensions
        let crop = asset.crop
        guard !asset.assetID.isEmpty,
              !asset.assetID.contains("/"),
              asset.sourceSHA256.count == 64,
              asset.sourceSizeBytes > 0,
              asset.frameCount > 0,
              asset.frameRange.start >= 0,
              asset.frameRange.duration > 0,
              asset.frameRange.timescale > 0,
              ["direct-2x", "direct-3over2"].contains(asset.targetRoute),
              crop.width == 324,
              crop.height == 192,
              crop.x == 2 * ((dimensions.width - 324) / 4),
              crop.y == 2 * ((dimensions.height - 192) / 4),
              crop.x >= 0,
              crop.y >= 0,
              crop.x.isMultiple(of: 2),
              crop.y.isMultiple(of: 2),
              asset.expectedMetadata.pixelFormat == "420v",
              asset.expectedMetadata.range == "video",
              asset.expectedMetadata.colorPrimaries == "ITU_R_709_2",
              asset.expectedMetadata.transferFunction == "ITU_R_709_2",
              asset.expectedMetadata.ycbcrMatrix == "ITU_R_709_2",
              asset.expectedMetadata.chromaLocation == "left" else {
            throw P07LoaderError.invalidPlan("asset \(asset.ordinal)")
        }
    }
    return plan
}

private func attachmentString(_ buffer: CVPixelBuffer, key: CFString) -> String? {
    guard let value = CVBufferCopyAttachment(buffer, key, nil) else { return nil }
    return value as? String
}

private func normalizedChromaLocation(_ value: String?) -> String? {
    guard let value else { return nil }
    if value == (kCVImageBufferChromaLocation_Left as String) || value.lowercased() == "left" {
        return "left"
    }
    return value
}

private func copyNV12Crop(_ buffer: CVPixelBuffer, crop: P07Crop) throws -> Data {
    guard CVPixelBufferGetPixelFormatType(buffer)
            == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
          CVPixelBufferGetPlaneCount(buffer) == 2,
          crop.x >= 0,
          crop.y >= 0,
          crop.width > 0,
          crop.height > 0,
          crop.x.isMultiple(of: 2),
          crop.y.isMultiple(of: 2),
          crop.width.isMultiple(of: 2),
          crop.height.isMultiple(of: 2),
          crop.x + crop.width <= CVPixelBufferGetWidthOfPlane(buffer, 0),
          crop.y + crop.height <= CVPixelBufferGetHeightOfPlane(buffer, 0),
          crop.x / 2 + crop.width / 2 <= CVPixelBufferGetWidthOfPlane(buffer, 1),
          crop.y / 2 + crop.height / 2 <= CVPixelBufferGetHeightOfPlane(buffer, 1) else {
        throw P07LoaderError.media("crop geometry or pixel format")
    }
    let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
    guard status == kCVReturnSuccess else {
        throw P07LoaderError.media("pixel buffer lock")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
          let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
        throw P07LoaderError.media("pixel plane base address")
    }
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    var result = Data(capacity: crop.width * crop.height * 3 / 2)
    for row in 0..<crop.height {
        let address = yBase.advanced(by: (crop.y + row) * yStride + crop.x)
        result.append(address.assumingMemoryBound(to: UInt8.self), count: crop.width)
    }
    for row in 0..<(crop.height / 2) {
        let address = cbcrBase.advanced(
            by: (crop.y / 2 + row) * cbcrStride + crop.x
        )
        result.append(address.assumingMemoryBound(to: UInt8.self), count: crop.width)
    }
    guard result.count == crop.width * crop.height * 3 / 2 else {
        throw P07LoaderError.output("cropped NV12 byte count")
    }
    return result
}

private func integerDimensions(
    naturalSize: CGSize,
    preferredTransform: CGAffineTransform
) throws -> P07Dimensions {
    let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
    let width = abs(transformed.width)
    let height = abs(transformed.height)
    let roundedWidth = width.rounded()
    let roundedHeight = height.rounded()
    guard width.isFinite,
          height.isFinite,
          abs(width - roundedWidth) < 1e-9,
          abs(height - roundedHeight) < 1e-9,
          roundedWidth > 0,
          roundedHeight > 0 else {
        throw P07LoaderError.media("nonintegral presentation dimensions")
    }
    return P07Dimensions(width: Int(roundedWidth), height: Int(roundedHeight))
}

private func validatePresentationOrder(
    _ pts: CMTime,
    previous: CMTime,
    label: String
) throws {
    guard CMTIME_IS_NUMERIC(pts) else {
        throw P07LoaderError.media("invalid sample time \(label)")
    }
    if CMTIME_IS_NUMERIC(previous), CMTimeCompare(pts, previous) < 0 {
        throw P07LoaderError.media("descending presentation timestamp \(label)")
    }
}

private func isAtOrAfterMidpoint(_ pts: CMTime, range: CMTimeRange) throws -> Bool {
    let offset = CMTimeSubtract(pts, range.start)
    let doubled = CMTimeMultiplyByRatio(offset, multiplier: 2, divisor: 1)
    guard CMTIME_IS_NUMERIC(doubled) else {
        throw P07LoaderError.media("invalid midpoint comparison")
    }
    return CMTimeCompare(doubled, range.duration) >= 0
}

private func firstMidpointIndex(
    _ presentationTimes: [CMTime],
    range: CMTimeRange,
    label: String
) throws -> Int? {
    var previous = CMTime.invalid
    for (index, pts) in presentationTimes.enumerated() {
        try validatePresentationOrder(pts, previous: previous, label: label)
        previous = pts
        if try isAtOrAfterMidpoint(pts, range: range) { return index }
    }
    return nil
}

private func extractAsset(
    _ item: P07AssetPlan,
    outputDirectoryDescriptor: Int32
) async throws -> [String: Any] {
    let payloadPath = "payloads/\(item.assetID).mp4"
    let beforeDigest = try P07FileIO.digestMountedRelative(payloadPath)
    guard beforeDigest.sha256 == item.sourceSHA256,
          beforeDigest.sizeBytes == item.sourceSizeBytes else {
        throw P07LoaderError.media("source bytes \(item.assetID)")
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: payloadPath))
    let tracks = try await asset.loadTracks(withMediaType: .video)
    var enabledTracks: [AVAssetTrack] = []
    for track in tracks where try await track.load(.isEnabled) {
        enabledTracks.append(track)
    }
    guard enabledTracks.count == 1, let track = enabledTracks.first else {
        throw P07LoaderError.media("enabled video track count \(item.assetID)")
    }
    let naturalSize = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let dimensions = try integerDimensions(
        naturalSize: naturalSize,
        preferredTransform: transform
    )
    guard dimensions == item.presentationDimensions,
          transform == .identity else {
        throw P07LoaderError.media("presentation geometry \(item.assetID)")
    }
    let trackRange = try await track.load(.timeRange)
    let requestedRange = CMTimeRange(
        start: CMTime(value: item.frameRange.start, timescale: item.frameRange.timescale),
        duration: CMTime(value: item.frameRange.duration, timescale: item.frameRange.timescale)
    )
    guard CMTimeCompare(trackRange.start, requestedRange.start) == 0,
          CMTimeCompare(trackRange.duration, requestedRange.duration) == 0 else {
        throw P07LoaderError.media("frame range \(item.assetID)")
    }
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = requestedRange
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw P07LoaderError.media("reader output unsupported \(item.assetID)")
    }
    reader.add(output)
    guard reader.startReading() else {
        throw P07LoaderError.media("reader start \(item.assetID)")
    }
    var chosenBuffer: CVPixelBuffer?
    var chosenPTS = CMTime.invalid
    var previousPTS = CMTime.invalid
    while let sample = output.copyNextSampleBuffer() {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        try validatePresentationOrder(
            pts,
            previous: previousPTS,
            label: item.assetID
        )
        previousPTS = pts
        if try isAtOrAfterMidpoint(pts, range: requestedRange) {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
                throw P07LoaderError.media("sample pixel buffer \(item.assetID)")
            }
            chosenBuffer = imageBuffer
            chosenPTS = pts
            break
        }
    }
    guard let pixelBuffer = chosenBuffer else {
        throw P07LoaderError.media("midpoint sample absent \(item.assetID)")
    }
    reader.cancelReading()
    guard CVPixelBufferGetWidth(pixelBuffer) == dimensions.width,
          CVPixelBufferGetHeight(pixelBuffer) == dimensions.height,
          CVPixelBufferGetPixelFormatType(pixelBuffer)
            == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
        throw P07LoaderError.media("decoded pixel geometry \(item.assetID)")
    }
    let observedPrimaries = attachmentString(pixelBuffer, key: kCVImageBufferColorPrimariesKey)
    let observedTransfer = attachmentString(pixelBuffer, key: kCVImageBufferTransferFunctionKey)
    let observedMatrix = attachmentString(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey)
    let observedChroma = normalizedChromaLocation(
        attachmentString(pixelBuffer, key: kCVImageBufferChromaLocationTopFieldKey)
    )
    guard observedPrimaries == item.expectedMetadata.colorPrimaries,
          observedTransfer == item.expectedMetadata.transferFunction,
          observedMatrix == item.expectedMetadata.ycbcrMatrix,
          observedChroma == item.expectedMetadata.chromaLocation else {
        throw P07LoaderError.media("decoded color metadata \(item.assetID)")
    }
    let cropBytes = try copyNV12Crop(pixelBuffer, crop: item.crop)
    let outputName = String(format: "%02d-%@.nv12", item.ordinal, item.assetID)
    try P07FileIO.writeNewAt(
        cropBytes,
        directoryDescriptor: outputDirectoryDescriptor,
        name: outputName
    )
    let reopened = try P07FileIO.digestAt(
        directoryDescriptor: outputDirectoryDescriptor,
        name: outputName
    )
    guard reopened.sha256 == P07FileIO.sha256(cropBytes),
          reopened.sizeBytes == cropBytes.count else {
        throw P07LoaderError.output("reopened crop \(item.assetID)")
    }
    let afterDigest = try P07FileIO.digestMountedRelative(payloadPath)
    guard afterDigest.sha256 == beforeDigest.sha256,
          afterDigest.sizeBytes == beforeDigest.sizeBytes else {
        throw P07LoaderError.media("source changed after decode \(item.assetID)")
    }
    return [
        "ordinal": item.ordinal,
        "asset_id": item.assetID,
        "source_asset_id": item.sourceAssetID,
        "source_family_id": item.sourceFamilyID,
        "target_route": item.targetRoute,
        "source_sha256": beforeDigest.sha256,
        "source_size_bytes": beforeDigest.sizeBytes,
        "source_rehashed_after_decode": true,
        "presentation_dimensions": ["width": dimensions.width, "height": dimensions.height],
        "preferred_transform": [
            "a": transform.a, "b": transform.b, "c": transform.c,
            "d": transform.d, "tx": transform.tx, "ty": transform.ty,
        ],
        "frame_range": [
            "start": item.frameRange.start,
            "duration": item.frameRange.duration,
            "timescale": item.frameRange.timescale,
        ],
        "selected_presentation_time": [
            "value": chosenPTS.value,
            "timescale": chosenPTS.timescale,
        ],
        "selection_rule": "first_presentation_order_sample_at_or_after_exact_range_midpoint",
        "enabled_video_track_count": enabledTracks.count,
        "decoded_pixel_format": "420v",
        "decoded_range": "video",
        "decoded_color_primaries": observedPrimaries!,
        "decoded_transfer_function": observedTransfer!,
        "decoded_ycbcr_matrix": observedMatrix!,
        "decoded_chroma_location": observedChroma!,
        "crop": [
            "x": item.crop.x,
            "y": item.crop.y,
            "width": item.crop.width,
            "height": item.crop.height,
        ],
        "crop_nv12_filename": outputName,
        "crop_nv12_sha256": reopened.sha256,
        "crop_nv12_size_bytes": reopened.sizeBytes,
    ]
}

private func runExtraction(_ values: [String: String]) async throws {
    let planDescriptor = values["--plan-fd"]!
    let expectedPlanSHA256 = values["--plan-sha256"]!
    let mountRoot = values["--mount-root"]!
    let outputDirectoryDescriptor = try P07FileIO.retainedDirectoryDescriptor(
        values["--output-directory-fd"]!,
        label: "output directory"
    )
    guard mountRoot == "." else {
        throw P07LoaderError.unsafePath(mountRoot)
    }
    let (planData, planDigest) = try P07FileIO.readRetainedDescriptor(
        planDescriptor,
        label: "sampling plan"
    )
    guard planDigest.sha256 == expectedPlanSHA256 else {
        throw P07LoaderError.invalidPlan("file hash")
    }
    let plan = try validatedPlan(planData)
    var rows: [[String: Any]] = []
    for item in plan.assets {
        rows.append(
            try await extractAsset(
                item,
                outputDirectoryDescriptor: outputDirectoryDescriptor
            )
        )
    }
    var document: [String: Any] = [
        "schema_version": "1.0.0",
        "artifact_kind": "p07_holdout_frame_extraction",
        "status": "complete",
        "sampling_plan_file_sha256": planDigest.sha256,
        "sampling_plan_manifest_sha256": plan.manifestSHA256,
        "corpus_manifest_sha256": plan.corpusManifestSHA256,
        "asset_count": rows.count,
        "assets": rows,
        "holdout_accessed": true,
        "target_pixel_hashes_recorded_after_open": true,
    ]
    document["manifest_sha256"] = P07FileIO.sha256(try canonicalJSON(document))
    let output = try canonicalJSON(document)
    try P07FileIO.writeNewAt(
        output + Data([0x0a]),
        directoryDescriptor: outputDirectoryDescriptor,
        name: "frame-extraction.json"
    )
    guard fsync(outputDirectoryDescriptor) == 0 else {
        throw P07LoaderError.fileWrite("output directory sync")
    }
    FileHandle.standardOutput.write(output + Data([0x0a]))
}

private func runSelfTest(_ values: [String: String]) throws {
    let outputDirectory = values["--output-directory"]!
    try P07FileIO.validateAbsolutePath(outputDirectory, finalMustBeDirectory: true)
    let timingRange = CMTimeRange(
        start: CMTime(value: 0, timescale: 10),
        duration: CMTime(value: 40, timescale: 10)
    )
    let monotonicTimes = [0, 10, 20, 30].map {
        CMTime(value: CMTimeValue($0), timescale: 10)
    }
    let tiedTimes = [0, 20, 20, 30].map {
        CMTime(value: CMTimeValue($0), timescale: 10)
    }
    guard try firstMidpointIndex(
        monotonicTimes,
        range: timingRange,
        label: "self-test-monotonic"
    ) == 2,
    try firstMidpointIndex(
        tiedTimes,
        range: timingRange,
        label: "self-test-tie"
    ) == 1 else {
        throw P07LoaderError.output("self-test midpoint ordering")
    }
    do {
        _ = try firstMidpointIndex(
            [
                CMTime(value: 0, timescale: 10),
                CMTime(value: 15, timescale: 10),
                CMTime(value: 10, timescale: 10),
                CMTime(value: 20, timescale: 10),
            ],
            range: timingRange,
            label: "self-test-descending"
        )
        throw P07LoaderError.output("self-test accepted descending timestamps")
    } catch P07LoaderError.media {
        // Expected fail-closed result.
    }
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:],
        kCVPixelBufferMetalCompatibilityKey: true,
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        328,
        196,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attributes as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        throw P07LoaderError.output("self-test pixel buffer")
    }
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
        throw P07LoaderError.output("self-test pixel buffer lock")
    }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
          let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
        CVPixelBufferUnlockBaseAddress(buffer, [])
        throw P07LoaderError.output("self-test plane address")
    }
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    for y in 0..<196 {
        let row = yBase.advanced(by: y * yStride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<328 { row[x] = UInt8((x + 3 * y) & 0xff) }
    }
    for y in 0..<98 {
        let row = cbcrBase.advanced(by: y * cbcrStride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<328 { row[x] = UInt8((5 * x + 7 * y) & 0xff) }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let crop = P07Crop(x: 2, y: 2, width: 324, height: 192)
    let first = try copyNV12Crop(buffer, crop: crop)
    let second = try copyNV12Crop(buffer, crop: crop)
    guard first == second, first.count == 93_312 else {
        throw P07LoaderError.output("self-test deterministic crop")
    }
    let outputPath = (outputDirectory as NSString).appendingPathComponent("self-test.nv12")
    try P07FileIO.writeNew(first, path: outputPath)
    let digest = try P07FileIO.digest(outputPath)
    guard digest.sha256 == P07FileIO.sha256(first), digest.sizeBytes == first.count else {
        throw P07LoaderError.output("self-test reopen")
    }
    var document: [String: Any] = [
        "schema_version": "1.0.0",
        "artifact_kind": "p07_holdout_frame_loader_self_test",
        "status": "pass",
        "input_dimensions": ["width": 328, "height": 196],
        "crop": ["x": 2, "y": 2, "width": 324, "height": 192],
        "nv12_size_bytes": digest.sizeBytes,
        "nv12_sha256": digest.sha256,
        "repeat_byte_identical": true,
        "presentation_order_monotonicity_checked": true,
        "midpoint_tie_selects_first": true,
        "descending_presentation_time_rejected": true,
        "holdout_accessed": false,
    ]
    document["manifest_sha256"] = P07FileIO.sha256(try canonicalJSON(document))
    let output = try canonicalJSON(document)
    FileHandle.standardOutput.write(output + Data([0x0a]))
}

@main
private struct P07HoldoutFrameLoaderMain {
    static func main() async {
        do {
            try waitForMirmirExecutionGate()
            _ = Darwin.umask(0o077)
            guard CommandLine.arguments.count >= 2 else {
                throw P07LoaderError.invalidArguments
            }
            switch CommandLine.arguments[1] {
            case "extract":
                let values = try P07Options(CommandLine.arguments.dropFirst(2)).require([
                    "--plan-fd", "--plan-sha256", "--mount-root",
                    "--output-directory-fd",
                ])
                try await runExtraction(values)
            case "self-test":
                let values = try P07Options(CommandLine.arguments.dropFirst(2)).require([
                    "--output-directory",
                ])
                try runSelfTest(values)
            default:
                throw P07LoaderError.invalidArguments
            }
        } catch {
            FileHandle.standardError.write(Data("P07 holdout frame loader failure: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }
}
