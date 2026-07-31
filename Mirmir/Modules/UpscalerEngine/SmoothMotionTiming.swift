import CoreMedia
import Foundation

enum SmoothMotionTimingError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible {
    case invalidPresentationTime
    case invalidInterval
    case timescaleOverflow
    case valueOverflow
    case nonMonotonicSubdivision

    var description: String {
        switch self {
        case .invalidPresentationTime:
            return "Smooth Motion received an invalid presentation timestamp."
        case .invalidInterval:
            return "Smooth Motion received a nonpositive frame interval."
        case .timescaleOverflow:
            return "Smooth Motion could not represent the subdivided timescale."
        case .valueOverflow:
            return "Smooth Motion could not represent a subdivided timestamp."
        case .nonMonotonicSubdivision:
            return "Smooth Motion cadence subdivision was not strictly monotonic."
        }
    }
}

struct SmoothMotionCadencePlanner: Sendable {
    let cadence: SmoothMotionCadence

    func timings(
        for source: FrameTiming,
        endingAt end: CMTime,
        outputStartIndex: Int
    ) throws -> [FrameTiming] {
        guard source.presentationTime.isValid,
              source.presentationTime.isNumeric,
              end.isValid,
              end.isNumeric else {
            throw SmoothMotionTimingError.invalidPresentationTime
        }
        return try timings(
            startingAt: source.presentationTime,
            duration: CMTimeSubtract(end, source.presentationTime),
            outputStartIndex: outputStartIndex
        )
    }

    func finalTimings(
        for source: FrameTiming,
        outputStartIndex: Int
    ) throws -> [FrameTiming] {
        try timings(
            startingAt: source.presentationTime,
            duration: source.duration,
            outputStartIndex: outputStartIndex
        )
    }

    private func timings(
        startingAt start: CMTime,
        duration: CMTime,
        outputStartIndex: Int
    ) throws -> [FrameTiming] {
        guard duration.isValid,
              duration.isNumeric,
              CMTimeCompare(duration, .zero) > 0 else {
            throw SmoothMotionTimingError.invalidInterval
        }
        let count = cadence.multiplier
        let boundaries = try (0...count).map {
            try boundary(
                start: start,
                duration: duration,
                numerator: $0,
                denominator: count
            )
        }
        var result: [FrameTiming] = []
        result.reserveCapacity(count)
        for offset in 0..<count {
            let sampleDuration = CMTimeSubtract(
                boundaries[offset + 1],
                boundaries[offset]
            )
            guard CMTimeCompare(sampleDuration, .zero) > 0,
                  offset == 0
                    || CMTimeCompare(
                        boundaries[offset],
                        boundaries[offset - 1]
                    ) > 0 else {
                throw SmoothMotionTimingError.nonMonotonicSubdivision
            }
            result.append(
                FrameTiming(
                    frameIndex: outputStartIndex + offset,
                    presentationTime: boundaries[offset],
                    duration: sampleDuration
                )
            )
        }
        return result
    }

    private func boundary(
        start: CMTime,
        duration: CMTime,
        numerator: Int,
        denominator: Int
    ) throws -> CMTime {
        let (timescale, timescaleOverflow) =
            duration.timescale.multipliedReportingOverflow(
                by: CMTimeScale(denominator)
            )
        guard !timescaleOverflow, timescale > 0 else {
            throw SmoothMotionTimingError.timescaleOverflow
        }
        let (value, valueOverflow) =
            duration.value.multipliedReportingOverflow(
                by: CMTimeValue(numerator)
            )
        guard !valueOverflow else {
            throw SmoothMotionTimingError.valueOverflow
        }
        return CMTimeAdd(
            start,
            CMTime(
                value: value,
                timescale: timescale,
                flags: duration.flags,
                epoch: duration.epoch
            )
        )
    }
}
