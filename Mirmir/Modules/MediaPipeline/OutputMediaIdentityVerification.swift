import CoreMedia
import CoreVideo
import CryptoKit
import Foundation

extension OutputMediaVerifier {
    static func verifyVideoColor(
        formatDescription: CMFormatDescription,
        expected: OutputMediaVideoColorExpectation
    ) throws {
        let extensions = (CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary?)
        try verifyVideoColorField(
            "full range video",
            expected: String(expected.isFullRangeVideo),
            actual: compressedVideoFullRangeValue(
                extensions?[kCMFormatDescriptionExtension_FullRangeVideo as String]
            ).map(String.init)
        )
        try verifyVideoColorField(
            "color primaries",
            expected: expected.colorPrimaries,
            actual: extensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        )
        try verifyVideoColorField(
            "transfer function",
            expected: expected.transferFunction,
            actual: extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        )
        try verifyVideoColorField(
            "YCbCr matrix",
            expected: expected.yCbCrMatrix,
            actual: extensions?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
        )
        try verifyVideoColorField(
            "chroma location",
            expected: expected.chromaLocation,
            actual: extensions?[
                kCMFormatDescriptionExtension_ChromaLocationTopField as String
            ] as? String
        )
    }

    private static func compressedVideoFullRangeValue(_ extensionValue: Any?) -> Bool? {
        // Core Media defines an absent FullRangeVideo extension as false for
        // YCbCr compressed formats. A present value must still be a CFBoolean.
        guard let extensionValue else { return false }
        guard let number = extensionValue as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    static func verifyDecodedVideoColor(
        pixelBuffer: CVPixelBuffer,
        expected: OutputMediaVideoColorExpectation
    ) throws {
        try verifyVideoColorField(
            "decoded color primaries",
            expected: expected.colorPrimaries,
            actual: CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                nil
            ) as? String
        )
        try verifyVideoColorField(
            "decoded transfer function",
            expected: expected.transferFunction,
            actual: CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferTransferFunctionKey,
                nil
            ) as? String
        )
        try verifyVideoColorField(
            "decoded YCbCr matrix",
            expected: expected.yCbCrMatrix,
            actual: CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferYCbCrMatrixKey,
                nil
            ) as? String
        )
        try verifyVideoColorField(
            "decoded chroma location",
            expected: expected.chromaLocation,
            actual: CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferChromaLocationTopFieldKey,
                nil
            ) as? String
        )
    }

    private static func verifyVideoColorField(
        _ field: String,
        expected: String,
        actual: String?
    ) throws {
        guard actual == expected else {
            throw OutputMediaVerificationError.videoColorMismatch(
                field: field,
                expected: expected,
                actual: actual
            )
        }
    }

    static func verifyCompressedAAC(
        _ actual: OutputMediaAACIdentity,
        expected: OutputMediaAACIdentity
    ) throws {
        guard actual.codec == expected.codec else {
            throw compressedAACMismatch(
                field: "codec",
                expected: fourCCString(expected.codec),
                actual: fourCCString(actual.codec)
            )
        }
        guard actual.sampleRate.bitPattern == expected.sampleRate.bitPattern else {
            throw compressedAACMismatch(
                field: "sample rate",
                expected: String(expected.sampleRate),
                actual: String(actual.sampleRate)
            )
        }
        guard actual.channelCount == expected.channelCount else {
            throw compressedAACMismatch(
                field: "channel count",
                expected: String(expected.channelCount),
                actual: String(actual.channelCount)
            )
        }
        guard actual.codecConfigurationMagicCookie
            == expected.codecConfigurationMagicCookie else {
            throw compressedAACMismatch(
                field: "codec configuration magic cookie",
                expected: dataIdentityDescription(expected.codecConfigurationMagicCookie),
                actual: dataIdentityDescription(actual.codecConfigurationMagicCookie)
            )
        }
        guard actual.channelLayout == expected.channelLayout else {
            throw compressedAACMismatch(
                field: "channel layout",
                expected: String(describing: expected.channelLayout),
                actual: String(describing: actual.channelLayout)
            )
        }
        try verifySemanticTimeRange(
            actual.trackTimeRange,
            expected: expected.trackTimeRange,
            field: "track time range"
        )
        guard actual.samples.count == expected.samples.count else {
            throw compressedAACMismatch(
                field: "compressed AAC access-unit count",
                expected: String(expected.samples.count),
                actual: String(actual.samples.count)
            )
        }
        for index in expected.samples.indices {
            let actualSample = actual.samples[index]
            let expectedSample = expected.samples[index]
            try verifySemanticTime(
                actualSample.presentationTime,
                expected: expectedSample.presentationTime,
                field: "access unit \(index) presentation time"
            )
            try verifySemanticTime(
                actualSample.decodeTime,
                expected: expectedSample.decodeTime,
                field: "access unit \(index) decode time"
            )
            try verifySemanticTime(
                actualSample.duration,
                expected: expectedSample.duration,
                field: "access unit \(index) duration"
            )
            guard actualSample.sampleCount == expectedSample.sampleCount else {
                throw compressedAACMismatch(
                    field: "access unit \(index) contained sample count",
                    expected: String(expectedSample.sampleCount),
                    actual: String(actualSample.sampleCount)
                )
            }
            guard actualSample.payloadByteCount == expectedSample.payloadByteCount else {
                throw compressedAACMismatch(
                    field: "access unit \(index) payload byte count",
                    expected: String(expectedSample.payloadByteCount),
                    actual: String(actualSample.payloadByteCount)
                )
            }
            guard actualSample.payloadSHA256 == expectedSample.payloadSHA256 else {
                throw compressedAACMismatch(
                    field: "access unit \(index) payload SHA-256",
                    expected: expectedSample.payloadSHA256,
                    actual: actualSample.payloadSHA256
                )
            }
        }
        guard actual.canonicalSHA256 == expected.canonicalSHA256 else {
            throw compressedAACMismatch(
                field: "canonical identity SHA-256",
                expected: expected.canonicalSHA256,
                actual: actual.canonicalSHA256
            )
        }
    }

    private static func verifySemanticTimeRange(
        _ actual: CMTimeRange,
        expected: CMTimeRange,
        field: String
    ) throws {
        try verifySemanticTime(
            actual.start,
            expected: expected.start,
            field: "\(field) start"
        )
        try verifySemanticTime(
            actual.duration,
            expected: expected.duration,
            field: "\(field) duration"
        )
    }

    private static func verifySemanticTime(
        _ actual: CMTime,
        expected: CMTime,
        field: String
    ) throws {
        guard semanticTimesAreEqual(actual, expected) else {
            throw compressedAACMismatch(
                field: field,
                expected: exactTimeDescription(expected),
                actual: exactTimeDescription(actual)
            )
        }
    }

    private static func semanticTimesAreEqual(
        _ actual: CMTime,
        _ expected: CMTime
    ) -> Bool {
        guard actual.isValid == expected.isValid else {
            return false
        }
        guard actual.isValid else {
            return true
        }
        guard actual.epoch == expected.epoch else {
            return false
        }
        if actual.isNumeric, expected.isNumeric {
            return CMTimeCompare(actual, expected) == 0
        }
        if actual.isPositiveInfinity || expected.isPositiveInfinity {
            return actual.isPositiveInfinity && expected.isPositiveInfinity
        }
        if actual.isNegativeInfinity || expected.isNegativeInfinity {
            return actual.isNegativeInfinity && expected.isNegativeInfinity
        }
        if actual.isIndefinite || expected.isIndefinite {
            return actual.isIndefinite && expected.isIndefinite
        }
        return actual.value == expected.value
            && actual.timescale == expected.timescale
            && actual.flags == expected.flags
    }

    private static func compressedAACMismatch(
        field: String,
        expected: String,
        actual: String
    ) -> OutputMediaVerificationError {
        .compressedAACMismatch(
            reason: "\(field): expected \(expected), observed \(actual)"
        )
    }

    private static func exactTimeDescription(_ time: CMTime) -> String {
        "value=\(time.value),timescale=\(time.timescale),flags=\(time.flags.rawValue),epoch=\(time.epoch)"
    }

    private static func dataIdentityDescription(_ data: Data) -> String {
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        return "bytes=\(data.count),sha256=\(digest)"

    }

    private static func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
