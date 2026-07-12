import CoreVideo
import CryptoKit
import Darwin
import Foundation
import Metal
import MetalPerformanceShaders

private func waitForMirmirExecutionGate() throws {
    guard let raw = ProcessInfo.processInfo.environment["MIRMIR_EXECUTION_GATE_FD"] else {
        return
    }
    guard let descriptor = Int32(raw), descriptor >= 0 else {
        throw ASHCalibrationP00Error.invalidArguments
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
        throw ASHCalibrationP00Error.invalidArguments
    }
}

enum ASHCalibrationP00Error: Error, CustomStringConvertible {
    case invalidArguments
    case unsafePath(String)
    case fileRead(String)
    case fileWrite(String)
    case invalidInput(String)
    case pixelBuffer(CVReturn)
    case outputValidation(String)

    var description: String {
        switch self {
        case .invalidArguments: "invalid arguments"
        case .unsafePath(let path): "unsafe path: \(path)"
        case .fileRead(let path): "file read failed: \(path)"
        case .fileWrite(let path): "file write failed: \(path)"
        case .invalidInput(let detail): "invalid input: \(detail)"
        case .pixelBuffer(let status): "pixel buffer error: \(status)"
        case .outputValidation(let detail): "output validation failed: \(detail)"
        }
    }
}

enum ASHCalibrationP00FileIO {
    static func validateDescriptor(
        _ descriptor: Int32,
        path: String,
        writableEmpty: Bool
    ) throws {
        var opened = stat()
        var linked = stat()
        guard fstat(descriptor, &opened) == 0,
              path.withCString({ lstat($0, &linked) }) == 0,
              linked.st_mode & S_IFMT != S_IFLNK,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_nlink == 1,
              opened.st_dev == linked.st_dev,
              opened.st_ino == linked.st_ino else {
            throw ASHCalibrationP00Error.unsafePath(path)
        }
        let access = fcntl(descriptor, F_GETFL) & O_ACCMODE
        if writableEmpty {
            guard access == O_RDWR, opened.st_size == 0 else {
                throw ASHCalibrationP00Error.fileWrite(path)
            }
        } else if access != O_RDONLY && access != O_RDWR {
            throw ASHCalibrationP00Error.fileRead(path)
        }
    }

    static func readDescriptor(_ descriptor: Int32) throws -> Data {
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              let size = Int(exactly: before.st_size),
              lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw ASHCalibrationP00Error.fileRead("descriptor")
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
                    throw ASHCalibrationP00Error.fileRead("descriptor")
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
            throw ASHCalibrationP00Error.fileRead("changed descriptor")
        }
        return data
    }

    static func writeDescriptor(_ data: Data, descriptor: Int32) throws {
        guard ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw ASHCalibrationP00Error.fileWrite("descriptor")
        }
        var offset = 0
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < data.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw ASHCalibrationP00Error.fileWrite("descriptor")
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0,
              try readDescriptor(descriptor) == data else {
            throw ASHCalibrationP00Error.fileWrite("descriptor")
        }
    }

    static func readRegular(_ path: String) throws -> Data {
        try validateComponents(path, finalMayBeMissing: false)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ASHCalibrationP00Error.fileRead(path) }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              let size = Int(exactly: before.st_size) else {
            throw ASHCalibrationP00Error.fileRead(path)
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
                guard count > 0 else { throw ASHCalibrationP00Error.fileRead(path) }
                offset += count
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw ASHCalibrationP00Error.fileRead("changed while reading \(path)")
        }
        return data
    }

    static func writeNew(_ data: Data, path: String) throws {
        try validateComponents(path, finalMayBeMissing: true)
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ASHCalibrationP00Error.fileWrite(path) }
        var complete = false
        defer {
            close(descriptor)
            if !complete { unlink(path) }
        }
        var offset = 0
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < data.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                guard count > 0 else { throw ASHCalibrationP00Error.fileWrite(path) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw ASHCalibrationP00Error.fileWrite(path)
        }
        complete = true
    }

    private static func validateComponents(
        _ path: String,
        finalMayBeMissing: Bool
    ) throws {
        let components = (path as NSString).pathComponents
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("//"),
              !components.contains("."),
              !components.contains("..") else {
            throw ASHCalibrationP00Error.unsafePath(path)
        }
        var cursor = "/"
        for (index, component) in components.dropFirst().enumerated() {
            cursor = (cursor as NSString).appendingPathComponent(component)
            var metadata = stat()
            let status = lstat(cursor, &metadata)
            let final = index == components.count - 2
            if status != 0 {
                if final && finalMayBeMissing { return }
                throw ASHCalibrationP00Error.fileRead(cursor)
            }
            guard metadata.st_mode & S_IFMT != S_IFLNK else {
                throw ASHCalibrationP00Error.unsafePath(cursor)
            }
            if final {
                guard metadata.st_mode & S_IFMT == S_IFREG else {
                    throw ASHCalibrationP00Error.unsafePath(cursor)
                }
            } else if metadata.st_mode & S_IFMT != S_IFDIR {
                throw ASHCalibrationP00Error.unsafePath(cursor)
            }
        }
    }
}

struct ASHCalibrationP00Options {
    let inputPath: String
    let outputPath: String
    let inputSHA256: String
    let width: Int
    let height: Int
    let route: String
    let inputDescriptor: Int32?
    let outputDescriptor: Int32?

    init(_ arguments: ArraySlice<String>) throws {
        guard arguments.count.isMultiple(of: 2) else {
            throw ASHCalibrationP00Error.invalidArguments
        }
        var values: [String: String] = [:]
        var cursor = arguments.startIndex
        while cursor < arguments.endIndex {
            let name = arguments[cursor]
            let valueIndex = arguments.index(after: cursor)
            guard name.hasPrefix("--"), values[name] == nil else {
                throw ASHCalibrationP00Error.invalidArguments
            }
            values[name] = arguments[valueIndex]
            cursor = arguments.index(after: valueIndex)
        }
        let baseKeys: Set<String> = [
            "--input", "--output", "--input-sha256", "--width", "--height", "--route"
        ]
        let descriptorKeys: Set<String> = ["--input-fd", "--output-fd"]
        let descriptorMode = !Set(values.keys).isDisjoint(with: descriptorKeys)
        guard Set(values.keys) == baseKeys.union(
            descriptorMode ? descriptorKeys : []
        ),
        let width = Int(values["--width"]!),
        let height = Int(values["--height"]!),
        width > 0,
        height > 0,
        width.isMultiple(of: 2),
        height.isMultiple(of: 2),
        ["direct-2x", "direct-3over2"].contains(values["--route"]!),
        values["--input-sha256"]!.count == 64 else {
            throw ASHCalibrationP00Error.invalidArguments
        }
        inputPath = values["--input"]!
        outputPath = values["--output"]!
        inputSHA256 = values["--input-sha256"]!
        self.width = width
        self.height = height
        route = values["--route"]!
        if descriptorMode {
            guard let input = Int32(values["--input-fd"]!),
                  let output = Int32(values["--output-fd"]!),
                  input >= 3,
                  output >= 3,
                  input != output else {
                throw ASHCalibrationP00Error.invalidArguments
            }
            inputDescriptor = input
            outputDescriptor = output
        } else {
            inputDescriptor = nil
            outputDescriptor = nil
        }
    }
}

@main
struct ASHCalibrationP00Main {
    static func main() async {
        do {
            try waitForMirmirExecutionGate()
            _ = Darwin.umask(0o077)
            guard CommandLine.arguments.count > 1,
                  CommandLine.arguments[1] == "process" else {
                throw ASHCalibrationP00Error.invalidArguments
            }
            let options = try ASHCalibrationP00Options(
                CommandLine.arguments.dropFirst(2)
            )
            if let inputDescriptor = options.inputDescriptor,
               let outputDescriptor = options.outputDescriptor {
                try ASHCalibrationP00FileIO.validateDescriptor(
                    inputDescriptor,
                    path: options.inputPath,
                    writableEmpty: false
                )
                try ASHCalibrationP00FileIO.validateDescriptor(
                    outputDescriptor,
                    path: options.outputPath,
                    writableEmpty: true
                )
            }
            let input = try options.inputDescriptor.map {
                try ASHCalibrationP00FileIO.readDescriptor($0)
            } ?? ASHCalibrationP00FileIO.readRegular(options.inputPath)
            guard input.count == options.width * options.height * 3 / 2,
                  sha256(input) == options.inputSHA256 else {
                throw ASHCalibrationP00Error.invalidInput("NV12 bytes or SHA-256")
            }
            let source = try pixelBuffer(width: options.width, height: options.height)
            try copyNV12(input, into: source)
            let exact2x = try pixelBuffer(
                width: options.width * 2,
                height: options.height * 2
            )
            let backend = ASHDeterministicUpscaleBackend(scale: 2, tileSize: 32)
            backend.reset()
            guard backend.lastDebugSummary == nil else {
                throw ASHCalibrationP00Error.outputValidation("backend reset")
            }
            try await backend.process(source: source, into: exact2x)

            let destination: CVPixelBuffer
            if options.route == "direct-2x" {
                destination = exact2x
            } else {
                let final = try pixelBuffer(
                    width: options.width * 3 / 2,
                    height: options.height * 3 / 2
                )
                let metal = try DefaultMetalRenderingService()
                try metal.start()
                defer { metal.stop() }
                try lanczosPolish(from: exact2x, to: final, metal: metal)
                destination = final
            }
            let output = try activeNV12(destination)
            if let outputDescriptor = options.outputDescriptor {
                try ASHCalibrationP00FileIO.writeDescriptor(
                    output,
                    descriptor: outputDescriptor
                )
            } else {
                try ASHCalibrationP00FileIO.writeNew(
                    output,
                    path: options.outputPath
                )
            }
            let reopened = try options.outputDescriptor.map {
                try ASHCalibrationP00FileIO.readDescriptor($0)
            } ?? ASHCalibrationP00FileIO.readRegular(options.outputPath)
            guard reopened == output else {
                throw ASHCalibrationP00Error.outputValidation("reopened output bytes")
            }
            try writeLine([
                "schema_version": "1.0.0",
                "status": "ok",
                "route": options.route,
                "input_nv12_sha256": sha256(input),
                "output_nv12_sha256": sha256(output),
                "input_width": options.width,
                "input_height": options.height,
                "output_width": CVPixelBufferGetWidth(destination),
                "output_height": CVPixelBufferGetHeight(destination),
                "pixel_format": "420v",
                "active_plane_stride_copy": true,
                "metal_iosurface_compatible_buffers": true,
                "tile_size": 32,
                "top_k": 1,
                "p00_backend_reset_before_frame": true,
                "p00_prior_frame_count": 0,
                "direct_3_over_2_postprocess": options.route == "direct-3over2"
                    ? "baseline_MPSImageLanczosScale_after_exact_2x"
                    : "not_applicable_exact_2x",
                "p00_lanczos_synchronization": options.route == "direct-3over2"
                    ? "hash_bound_adapter_commit_then_wait_until_completed"
                    : "not_applicable",
                "process_id": Int(ProcessInfo.processInfo.processIdentifier)
            ])
        } catch {
            FileHandle.standardError.write(Data("P00 helper failure: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: NSNumber(value: width),
            kCVPixelBufferHeightKey as String: NSNumber(value: height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw ASHCalibrationP00Error.pixelBuffer(status)
        }
        return buffer
    }

    private static func copyNV12(_ data: Data, into buffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw ASHCalibrationP00Error.outputValidation("input pixel buffer lock")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        guard data.count == width * height * 3 / 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            throw ASHCalibrationP00Error.invalidInput("input plane geometry")
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        try data.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            for row in 0..<height {
                memcpy(yBase.advanced(by: row * yStride), source.advanced(by: row * width), width)
            }
            let uvSource = source.advanced(by: width * height)
            for row in 0..<(height / 2) {
                memcpy(uvBase.advanced(by: row * uvStride), uvSource.advanced(by: row * width), width)
            }
        }
    }

    private static func activeNV12(_ buffer: CVPixelBuffer) throws -> Data {
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw ASHCalibrationP00Error.outputValidation("output pixel buffer lock")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            throw ASHCalibrationP00Error.outputValidation("output plane geometry")
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        var output = Data()
        output.reserveCapacity(width * height * 3 / 2)
        for row in 0..<height {
            output.append(yBase.advanced(by: row * yStride).assumingMemoryBound(to: UInt8.self), count: width)
        }
        for row in 0..<(height / 2) {
            output.append(uvBase.advanced(by: row * uvStride).assumingMemoryBound(to: UInt8.self), count: width)
        }
        return output
    }

    private static func lanczosPolish(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        metal: MetalRenderingService
    ) throws {
        try lanczosPlane(
            planeIndex: 0,
            format: .r8Unorm,
            source: source,
            destination: destination,
            metal: metal
        )
        if CVPixelBufferGetPlaneCount(source) > 1,
           CVPixelBufferGetPlaneCount(destination) > 1 {
            try lanczosPlane(
                planeIndex: 1,
                format: .rg8Unorm,
                source: source,
                destination: destination,
                metal: metal
            )
        }
    }

    private static func lanczosPlane(
        planeIndex: Int,
        format: MTLPixelFormat,
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        metal: MetalRenderingService
    ) throws {
        let (sourceCV, sourceTexture) = try PixelBufferBridge.makeTexture(
            from: source,
            cache: metal.textureCache,
            pixelFormat: format,
            planeIndex: planeIndex
        )
        let (destinationCV, destinationTexture) = try PixelBufferBridge.makeTexture(
            from: destination,
            cache: metal.textureCache,
            pixelFormat: format,
            planeIndex: planeIndex
        )
        _ = (sourceCV, destinationCV)
        guard let commandBuffer = metal.commandQueue.makeCommandBuffer() else {
            throw ASHCalibrationP00Error.outputValidation("Lanczos command buffer")
        }
        let lanczos = MPSImageLanczosScale(device: metal.device)
        var transform = MPSScaleTransform(
            scaleX: Double(destinationTexture.width) / Double(sourceTexture.width),
            scaleY: Double(destinationTexture.height) / Double(sourceTexture.height),
            translateX: 0,
            translateY: 0
        )
        withUnsafePointer(to: &transform) { pointer in
            lanczos.scaleTransform = pointer
            lanczos.encode(
                commandBuffer: commandBuffer,
                sourceTexture: sourceTexture,
                destinationTexture: destinationTexture
            )
            lanczos.scaleTransform = nil
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw ASHCalibrationP00Error.outputValidation(
                "Lanczos command buffer status \(commandBuffer.status.rawValue)"
            )
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeLine(_ object: Any) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ASHCalibrationP00Error.outputValidation("response JSON")
        }
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}
