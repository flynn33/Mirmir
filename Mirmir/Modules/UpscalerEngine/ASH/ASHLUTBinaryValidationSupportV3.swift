import CryptoKit
import Foundation

extension ASHLUTBinaryCodecV3 {
    static func validationSHA256(_ data: Data) -> ASHLUTHashV3 {
        ASHLUTHashV3(validatedBytes: Array(SHA256.hash(data: data)))
    }

    static func adjustedForValidation(
        _ base: UInt16,
        delta: Int8,
        step: UInt16,
        range: ClosedRange<Int>
    ) -> UInt16 {
        let value = Int(base) + (Int(delta) * Int(step))
        return UInt16(min(range.upperBound, max(range.lowerBound, value)))
    }
    static func checkedValidationAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow, result.partialValue <= UInt64(UInt32.max) else {
            throw ASHLUTBinaryErrorV3.offsetOrSizeOverflow
        }
        return result.partialValue
    }

    static func checkedValidationMultiply(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow, result.partialValue <= UInt64(UInt32.max) else {
            throw ASHLUTBinaryErrorV3.offsetOrSizeOverflow
        }
        return result.partialValue
    }
}
