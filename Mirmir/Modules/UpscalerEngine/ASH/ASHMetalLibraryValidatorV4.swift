import Foundation
import Metal
import Dispatch

enum ASHSystemMetalLibraryValidatorV4Error: Error, Equatable, Sendable {
    case metalUnavailable
    case emptyFunctionSet
}

/// Production validator used by the P06 build tool and runtime composition
/// root. `makeLibrary(data:)` asks Metal to parse and load the exact bytes; this
/// closes the gap left by checking only the `MTLB` file signature.
struct ASHSystemMetalLibraryValidatorV4: ASHMetalLibraryValidatingV4,
    @unchecked Sendable {
    private let device: any MTLDevice

    init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else {
            throw ASHSystemMetalLibraryValidatorV4Error.metalUnavailable
        }
        self.device = device
    }

    func validateExecutableMetalLibrary(_ data: Data) throws {
        let dispatchData = data.withUnsafeBytes { bytes in
            DispatchData(bytes: bytes)
        }
        let library = try device.makeLibrary(data: dispatchData)
        guard !library.functionNames.isEmpty else {
            throw ASHSystemMetalLibraryValidatorV4Error.emptyFunctionSet
        }
    }
}
