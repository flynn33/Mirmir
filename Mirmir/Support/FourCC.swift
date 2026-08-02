import CoreMedia
import Foundation

enum FourCC {
    static func string(from value: FourCharCode?) -> String? {
        guard let value else {
            return nil
        }

        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        guard bytes.allSatisfy({ (0x20...0x7e).contains($0) }) else {
            return nil
        }
        return String(bytes: bytes, encoding: .ascii)
    }
}
