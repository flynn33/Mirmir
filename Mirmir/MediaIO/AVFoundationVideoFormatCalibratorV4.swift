import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum AVFoundationVideoFormatCalibratorV4Error: Error, Equatable, Sendable {
    case writerCreationFailed(String)
    case writerStartFailed(String)
    case pixelBufferPoolUnavailable
    case pixelBufferAllocationFailed(Int32)
    case pixelBufferLayoutInvalid
    case writerAppendFailed(String)
    case writerFinishFailed(String)
    case encodedVideoTrackMissing
    case encodedFormatDescriptionMissing
    case decodedSampleMissing
}

/// Calibrates AVAssetWriter's actual encoded sample description before a
/// processed track enters an immutable migration plan. AVFoundation may add
/// codec atoms and profile data that cannot be inferred from output settings;
/// this actor records the descriptor produced by the same contract and caches
/// it by the complete, hashable semantic contract.
actor AVFoundationVideoFormatCalibratorV4 {
    private var cached: [
        VideoWriterFormatContractV4: MediaTrackFormatDescriptorV4
    ] = [:]

    func formatDescriptor(
        for contract: VideoWriterFormatContractV4
    ) async throws -> MediaTrackFormatDescriptorV4 {
        if let cached = cached[contract] {
            return cached
        }
        let calibrated = try await calibrate(contract)
        cached[contract] = calibrated
        return calibrated
    }

    private func calibrate(
        _ contract: VideoWriterFormatContractV4
    ) async throws -> MediaTrackFormatDescriptorV4 {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-v4-format-calibration-\(UUID().uuidString)"
            )
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw AVFoundationVideoFormatCalibratorV4Error
                .writerCreationFailed(stableFailure(error))
        }
        let endpoint = try contract.makeEndpoint(writer: writer)
        guard writer.startWriting() else {
            throw AVFoundationVideoFormatCalibratorV4Error
                .writerStartFailed(stableFailure(writer.error))
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = endpoint.adaptor.pixelBufferPool else {
            writer.cancelWriting()
            throw AVFoundationVideoFormatCalibratorV4Error
                .pixelBufferPoolUnavailable
        }
        let pixelBuffer = try allocate(from: pool)
        try fillCalibrationSignal(pixelBuffer, contract: contract)
        contract.applyChromaSiting(to: pixelBuffer)
        guard endpoint.input.isReadyForMoreMediaData,
              endpoint.adaptor.append(pixelBuffer, withPresentationTime: .zero)
        else {
            writer.cancelWriting()
            throw AVFoundationVideoFormatCalibratorV4Error
                .writerAppendFailed(stableFailure(writer.error))
        }
        endpoint.input.markAsFinished()
        await finish(writer)
        guard writer.status == .completed else {
            throw AVFoundationVideoFormatCalibratorV4Error
                .writerFinishFailed(stableFailure(writer.error))
        }

        try await contract.finalizeEncodedMetadata(at: url)
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw AVFoundationVideoFormatCalibratorV4Error
                .encodedVideoTrackMissing
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else {
            throw AVFoundationVideoFormatCalibratorV4Error
                .encodedFormatDescriptionMissing
        }
        try contract.verifyReopenedFormat(
            description,
            preferredTransform: try await track.load(.preferredTransform)
        )
        try await verifyDecodedPixel(
            asset: asset,
            track: track,
            contract: contract,
            encodedFormatDescription: description
        )
        return try AVFoundationTrackGraphAdapterV4
            .canonicalFormatDescriptor(description)
    }

    private func allocate(
        from pool: CVPixelBufferPool
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw AVFoundationVideoFormatCalibratorV4Error
                .pixelBufferAllocationFailed(status)
        }
        return pixelBuffer
    }

    private func fillCalibrationSignal(
        _ pixelBuffer: CVPixelBuffer,
        contract: VideoWriterFormatContractV4
    ) throws {
        do {
            try PixelLayoutV4(storage: contract.storage)
                .validateStructure(of: pixelBuffer)
        } catch {
            throw AVFoundationVideoFormatCalibratorV4Error
                .pixelBufferLayoutInvalid
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            let componentCount = plane == 0 ? 1 : 2
            if contract.storage.signalBitDepth == 8 {
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(
                    pixelBuffer,
                    plane
                )
                guard let address = CVPixelBufferGetBaseAddressOfPlane(
                    pixelBuffer,
                    plane
                ) else {
                    throw AVFoundationVideoFormatCalibratorV4Error
                        .pixelBufferLayoutInvalid
                }
                let value: UInt8
                if plane == 0 {
                    value = contract.storage.codeRange == .video ? 16 : 0
                } else {
                    value = 128
                }
                for row in 0..<height {
                    memset(address.advanced(by: row * rowBytes), Int32(value),
                        width * componentCount)
                }
            } else {
                let rowComponents = CVPixelBufferGetBytesPerRowOfPlane(
                    pixelBuffer,
                    plane
                ) / MemoryLayout<UInt16>.stride
                guard let base = CVPixelBufferGetBaseAddressOfPlane(
                    pixelBuffer,
                    plane
                )?.assumingMemoryBound(to: UInt16.self) else {
                    throw AVFoundationVideoFormatCalibratorV4Error
                        .pixelBufferLayoutInvalid
                }
                let signal: UInt16
                if plane == 0 {
                    signal = contract.storage.codeRange == .video ? 64 : 0
                } else {
                    signal = 512
                }
                let stored = signal << 6
                for row in 0..<height {
                    for component in 0..<(width * componentCount) {
                        base[row * rowComponents + component] = stored
                    }
                }
            }
        }
        if case .hdr(let metadata) = contract.color {
            try AVFoundationHDRMetadataAdapterV4.migrate(
                metadata,
                to: pixelBuffer
            )
        }
    }

    private func verifyDecodedPixel(
        asset: AVAsset,
        track: AVAssetTrack,
        contract: VideoWriterFormatContractV4,
        encodedFormatDescription: CMFormatDescription
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    NSNumber(value: contract.storage.pixelFormat)
            ]
        )
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw AVFoundationVideoFormatCalibratorV4Error
                .decodedSampleMissing
        }
        reader.add(output)
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            throw AVFoundationVideoFormatCalibratorV4Error
                .decodedSampleMissing
        }
        try contract.verifyDecodedPixelBuffer(
            pixelBuffer, encodedFormatDescription: encodedFormatDescription
        )
        while output.copyNextSampleBuffer() != nil {}
        guard reader.status == .completed else {
            throw AVFoundationVideoFormatCalibratorV4Error
                .decodedSampleMissing
        }
    }

    private func finish(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
    }

    private func stableFailure(_ error: Error?) -> String {
        guard let error else { return "none" }
        let value = error as NSError
        return "\(value.domain):\(value.code)"
    }
}
