import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

enum PreparedFrameUpscalerTrackHookV4Error: Error, Equatable, Sendable {
    case invalidNominalSourceFrameDuration
    case invalidStartingFrameIndex(Int)
    case invalidMaximumOutputCount(Int)
    case destinationPoolCreationFailed(Int32)
    case destinationAllocationFailed(Int32)
    case sourceSampleHasNoImageBuffer(frameIndex: Int)
    case sourceSampleHasInvalidPresentationTime(frameIndex: Int)
    case backendOutputCountMismatch(
        frameIndex: Int,
        expected: Int,
        actual: Int
    )
    case backendOutputHasInvalidPresentationTime(
        frameIndex: Int,
        outputOrdinal: Int
    )
    case outputFormatDescriptionCreationFailed(
        frameIndex: Int,
        outputOrdinal: Int,
        status: Int32
    )
    case outputSampleCreationFailed(
        frameIndex: Int,
        outputOrdinal: Int,
        status: Int32
    )
    case alreadyFinished
}

/// Adapts the prepared per-frame engine to the whole-asset track migrator.
/// The actor owns frame ordinals, a bounded destination pool, and backend
/// finalization, keeping those stateful details out of the migration closure.
actor PreparedFrameUpscalerTrackProcessorV4 {
    private let backend: any PreparedFrameUpscaler
    private let temporalBackend: (any PreparedTemporalFrameUpscaler)?
    private let pool: CVPixelBufferPool
    private let nominalSourceFrameDuration: CMTime
    private let maximumOutputCount: Int
    private let finishBackendAtEnd: Bool
    private var nextFrameIndex: Int
    private var finished = false

    init(
        backend: any PreparedFrameUpscaler,
        nominalSourceFrameDuration: ExactRationalV4,
        startingFrameIndex: Int = 0,
        finishBackendAtEnd: Bool = true
    ) throws {
        guard nominalSourceFrameDuration.numerator > 0,
              nominalSourceFrameDuration.denominator <= Int64(Int32.max) else {
            throw PreparedFrameUpscalerTrackHookV4Error
                .invalidNominalSourceFrameDuration
        }
        guard startingFrameIndex >= 0 else {
            throw PreparedFrameUpscalerTrackHookV4Error
                .invalidStartingFrameIndex(startingFrameIndex)
        }
        let temporal = backend as? any PreparedTemporalFrameUpscaler
        let maximum = temporal?.maximumOutputFramesPerInput ?? 1
        guard maximum > 0, maximum <= Int(Int32.max) else {
            throw PreparedFrameUpscalerTrackHookV4Error
                .invalidMaximumOutputCount(maximum)
        }
        var createdPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [
                kCVPixelBufferPoolMinimumBufferCountKey as String:
                    NSNumber(value: maximum * 2)
            ] as CFDictionary,
            backend.destinationPixelBufferAttributes.values as CFDictionary,
            &createdPool
        )
        guard status == kCVReturnSuccess, let createdPool else {
            throw PreparedFrameUpscalerTrackHookV4Error
                .destinationPoolCreationFailed(status)
        }
        self.backend = backend
        self.temporalBackend = temporal
        self.pool = createdPool
        self.nominalSourceFrameDuration = CMTime(
            value: nominalSourceFrameDuration.numerator,
            timescale: Int32(nominalSourceFrameDuration.denominator)
        )
        self.maximumOutputCount = maximum
        self.finishBackendAtEnd = finishBackendAtEnd
        self.nextFrameIndex = startingFrameIndex
    }

    func process(
        _ input: AVFoundationVideoSampleV4
    ) async throws -> [AVFoundationVideoSampleV4] {
        guard !finished else {
            throw PreparedFrameUpscalerTrackHookV4Error.alreadyFinished
        }
        let frameIndex = nextFrameIndex
        let sourceSample = input.sampleBuffer
        let sourceDynamicHDRMetadata = try AVFoundationHDRMetadataAdapterV4
            .probeDynamicMetadata(from: sourceSample)
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sourceSample) else {
            throw PreparedFrameUpscalerTrackHookV4Error
                .sourceSampleHasNoImageBuffer(frameIndex: frameIndex)
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(
            sourceSample
        )
        guard presentationTime.isNumeric else {
            throw PreparedFrameUpscalerTrackHookV4Error
                .sourceSampleHasInvalidPresentationTime(frameIndex: frameIndex)
        }
        let observedDuration = CMSampleBufferGetDuration(sourceSample)
        let sourceDuration = observedDuration.isNumeric
            && observedDuration.value > 0
            ? observedDuration
            : nominalSourceFrameDuration
        let timing = FrameTiming(
            frameIndex: frameIndex,
            presentationTime: presentationTime,
            duration: sourceDuration
        )
        var destinations: [FramePixelBuffer] = []
        destinations.reserveCapacity(maximumOutputCount)
        for _ in 0..<maximumOutputCount {
            destinations.append(FramePixelBuffer(try allocateDestination()))
        }

        let processed: [TemporalOutputFrame]
        if let temporalBackend {
            processed = try await temporalBackend.processTemporal(
                source: FramePixelBuffer(sourceBuffer),
                destinations: destinations,
                timing: timing
            )
        } else {
            try await backend.process(
                source: FramePixelBuffer(sourceBuffer),
                destination: destinations[0],
                timing: timing
            )
            processed = [TemporalOutputFrame(
                pixelBuffer: destinations[0],
                presentationTime: presentationTime
            )]
        }
        guard processed.count == maximumOutputCount else {
            throw PreparedFrameUpscalerTrackHookV4Error
                .backendOutputCountMismatch(
                    frameIndex: frameIndex,
                    expected: maximumOutputCount,
                    actual: processed.count
                )
        }

        let outputDuration = CMTimeMultiplyByRatio(
            sourceDuration,
            multiplier: 1,
            divisor: Int32(maximumOutputCount)
        )
        let sourceDecodeTime = CMSampleBufferGetDecodeTimeStamp(sourceSample)
        var output: [AVFoundationVideoSampleV4] = []
        output.reserveCapacity(processed.count)
        for (ordinal, frame) in processed.enumerated() {
            guard frame.presentationTime.isNumeric else {
                throw PreparedFrameUpscalerTrackHookV4Error
                    .backendOutputHasInvalidPresentationTime(
                        frameIndex: frameIndex,
                        outputOrdinal: ordinal
                    )
            }
            var format: CMVideoFormatDescription?
            let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer.value,
                formatDescriptionOut: &format
            )
            guard formatStatus == noErr, let format else {
                throw PreparedFrameUpscalerTrackHookV4Error
                    .outputFormatDescriptionCreationFailed(
                        frameIndex: frameIndex,
                        outputOrdinal: ordinal,
                        status: formatStatus
                    )
            }
            let offset = CMTimeMultiply(
                outputDuration,
                multiplier: Int32(ordinal)
            )
            var sampleTiming = CMSampleTimingInfo(
                duration: outputDuration,
                presentationTimeStamp: frame.presentationTime,
                decodeTimeStamp: sourceDecodeTime.isNumeric
                    ? CMTimeAdd(sourceDecodeTime, offset)
                    : sourceDecodeTime
            )
            var sample: CMSampleBuffer?
            let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer.value,
                formatDescription: format,
                sampleTiming: &sampleTiming,
                sampleBufferOut: &sample
            )
            guard sampleStatus == noErr, let sample else {
                throw PreparedFrameUpscalerTrackHookV4Error
                    .outputSampleCreationFailed(
                        frameIndex: frameIndex,
                        outputOrdinal: ordinal,
                        status: sampleStatus
                    )
            }
            if let sourceDynamicHDRMetadata {
                try AVFoundationHDRMetadataAdapterV4.migrate(
                    sourceDynamicHDRMetadata,
                    to: sample
                )
            }
            output.append(AVFoundationVideoSampleV4(sampleBuffer: sample))
        }
        nextFrameIndex += 1
        return output
    }

    func finish() async throws {
        guard !finished else { return }
        if finishBackendAtEnd {
            try await backend.finish()
        }
        finished = true
    }

    private func allocateDestination() throws -> CVPixelBuffer {
        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &destination
        )
        guard status == kCVReturnSuccess, let destination else {
            throw PreparedFrameUpscalerTrackHookV4Error
                .destinationAllocationFailed(status)
        }
        return destination
    }
}

enum PreparedFrameUpscalerTrackHookV4 {
    static func make(
        trackID: MediaTrackStableIDV4,
        preparedBackend: any PreparedFrameUpscaler,
        writerOutputSettings: [String: Any],
        declaredOutputFormats: [MediaTrackFormatDescriptorV4],
        outputHDRMetadata: HDRFormatMetadataV4? = nil,
        nominalSourceFrameDuration: ExactRationalV4,
        outputPreferredTransform: CGAffineTransform? = nil,
        outputNaturalSize: CGSize? = nil,
        startingFrameIndex: Int = 0,
        finishBackendAtEnd: Bool = true
    ) throws -> AVFoundationVideoTrackProcessingHookV4 {
        let outputCount = (preparedBackend
            as? any PreparedTemporalFrameUpscaler)?
            .maximumOutputFramesPerInput ?? 1
        let processor = try PreparedFrameUpscalerTrackProcessorV4(
            backend: preparedBackend,
            nominalSourceFrameDuration: nominalSourceFrameDuration,
            startingFrameIndex: startingFrameIndex,
            finishBackendAtEnd: finishBackendAtEnd
        )
        return AVFoundationVideoTrackProcessingHookV4(
            trackID: trackID,
            readerOutputSettings:
                preparedBackend.sourcePixelBufferAttributes.values,
            writerOutputSettings: writerOutputSettings,
            declaredOutputFormats: declaredOutputFormats,
            outputHDRMetadata: outputHDRMetadata,
            outputPreferredTransform: outputPreferredTransform,
            outputNaturalSize: outputNaturalSize,
            outputTimingContract: .uniformlySubdivideSourceInterval(
                outputCount: outputCount,
                invalidSourceDurationFallback: nominalSourceFrameDuration
            ),
            processTemporal: { sample in
                try await processor.process(sample)
            },
            finish: {
                try await processor.finish()
            }
        )
    }
}
