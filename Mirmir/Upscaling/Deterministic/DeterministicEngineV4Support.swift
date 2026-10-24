import CoreVideo
import Dispatch
import Foundation
import Metal

enum ASHP06RuntimeProviderV4Error: Error, Equatable, Sendable {
    case bundleResourceMissing(String)
    case productionTrustRootNotConfigured
    case metalLibraryLoadFailed(String)
}

/// Code-owned trust roots for the shipping P06 bundle. The values are replaced
/// only by the reproducible release-bundle build; runtime code never derives a
/// trust root from the manifest it is about to validate.
enum ASHProductionP06TrustRootV4 {
    static let bundleName = "ASH-P06"
    static let bundleExtension = "bundle"

    // A zero identity is deliberately non-loadable. The reproducible P06 build
    // patches these three constants together with the checked-in bundle.
    static let manifestSHA256 = try! ASHSHA256V4(
        "6daf3fd94f1dcf556c117fc525e7cc25a64e01e68c2bbfb2b19757c3781f3c70"
    )
    static let sourceRevision =
        "68c363ca3e5ae6dfef27f35e3121a147ddc4dd0047b20f89cbae08cdfabecf87"
    static let builderSourceSHA256 = try! ASHSHA256V4(
        "40aad241a07eda3f63919eed2b126eb7dc62777be9bd6520cf2b5a3c824c6dc9"
    )

    static var isConfigured: Bool {
        manifestSHA256.rawValue != String(repeating: "0", count: 64)
            && isConfiguredSourceRevision(sourceRevision)
            && builderSourceSHA256.rawValue
                != String(repeating: "0", count: 64)
    }

    /// Provenance accepts Git SHA-1 and SHA-256 spellings, but neither all-zero
    /// sentinel is a deployable trust root. Keeping this check independent of
    /// the checked-in constant makes both accepted lengths testable.
    static func isConfiguredSourceRevision(_ value: String) -> Bool {
        guard value.utf8.count == 40 || value.utf8.count == 64,
              value.utf8.allSatisfy({
                  (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
              }) else {
            return false
        }
        return value.utf8.contains { $0 != 0x30 }
    }
}

/// Thread-safe composition root for a verified P06 runtime. Successful loads
/// are retained as immutable bytes. Failures are not cached so installation or
/// test-fixture changes can be observed without restarting the process.
final class ASHP06RuntimeProviderV4: @unchecked Sendable {
    typealias Loader = @Sendable () throws -> ASHVerifiedRuntimeBundleV4

    private let loader: Loader
    private let lock = NSLock()
    private var cached: ASHVerifiedRuntimeBundleV4?

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func load() throws -> ASHVerifiedRuntimeBundleV4 {
        if let value = lock.withLock({ cached }) {
            try value.verifyBinding()
            return value
        }
        let loaded = try loader()
        try loaded.verifyBinding()
        return lock.withLock {
            if let cached {
                return cached
            }
            cached = loaded
            return loaded
        }
    }

    static func fixed(_ runtime: ASHVerifiedRuntimeBundleV4) -> Self {
        Self { runtime }
    }

    static func production(bundle: Bundle = .main) -> Self {
        let bundleURL = bundle.url(
            forResource: ASHProductionP06TrustRootV4.bundleName,
            withExtension: ASHProductionP06TrustRootV4.bundleExtension
        )
        return Self {
            guard ASHProductionP06TrustRootV4.isConfigured else {
                throw ASHP06RuntimeProviderV4Error
                    .productionTrustRootNotConfigured
            }
            guard let bundleURL else {
                throw ASHP06RuntimeProviderV4Error.bundleResourceMissing(
                    "\(ASHProductionP06TrustRootV4.bundleName)."
                        + ASHProductionP06TrustRootV4.bundleExtension
                )
            }
            let policy = try ASHRuntimeTrustPolicyV4(
                expectedManifestSHA256:
                    ASHProductionP06TrustRootV4.manifestSHA256,
                allowedSourceRevisions: [
                    ASHProductionP06TrustRootV4.sourceRevision
                ],
                allowedBuilderSourceSHA256: [
                    ASHProductionP06TrustRootV4.builderSourceSHA256
                ]
            )
            return try ASHP06RuntimeBundleLoaderV4.load(
                at: bundleURL,
                trustPolicy: policy,
                metalLibraryValidator: try ASHSystemMetalLibraryValidatorV4()
            )
        }
    }
}

enum DeterministicScanModeV4: Equatable, Sendable {
    case progressive
    case interlaced(FieldDominanceV4)
}

struct DeterministicPreparedConfigurationV4: Sendable {
    let backendID: UpscaleBackendID
    let executionBackend: FixedPointExecutionBackendV4
    let storage: PixelStorageV4
    let sourceWidth: Int
    let sourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int
    let scanMode: DeterministicScanModeV4

    var sourceAttributes: PixelBufferAttributes {
        attributes(width: sourceWidth, height: sourceHeight)
    }

    var destinationAttributes: PixelBufferAttributes {
        attributes(width: targetWidth, height: targetHeight)
    }

    var scaleRouteIdentity: String {
        let horizontal = reducedRatio(targetWidth, sourceWidth)
        let vertical = reducedRatio(targetHeight, sourceHeight)
        return "x=\(horizontal.0)/\(horizontal.1);y="
            + "\(vertical.0)/\(vertical.1)"
    }

    func processingError(
        _ details: String,
        frameIndex: Int? = nil
    ) -> MirmirError {
        .backendProcessingFailed(
            backendID: backendID,
            frameIndex: frameIndex,
            details: details
        )
    }

    private func attributes(width: Int, height: Int) -> PixelBufferAttributes {
        var values: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: storage.pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        if executionBackend == .metal {
            values[kCVPixelBufferMetalCompatibilityKey as String] = true
        }
        return PixelBufferAttributes(values)
    }

    private func reducedRatio(_ numerator: Int, _ denominator: Int) -> (Int, Int) {
        var left = numerator
        var right = denominator
        while right != 0 {
            (left, right) = (right, left % right)
        }
        return (numerator / left, denominator / left)
    }
}

enum DeterministicConfigurationValidatorV4 {
    static func validate(
        source: VideoInfo,
        targetSize: CGSize,
        backendID: UpscaleBackendID,
        executionBackend: FixedPointExecutionBackendV4
    ) -> Result<DeterministicPreparedConfigurationV4, BackendUnavailableReason> {
        let sourceSize = source.geometry.encodedSize ?? source.naturalSize
        guard let sourceDimensions = integerDimensions(sourceSize) else {
            return .failure(.unsupportedSourceDimensions(
                width: safeDimension(sourceSize.width),
                height: safeDimension(sourceSize.height),
                details: "v4 requires a positive integral encoded raster"
            ))
        }
        guard let targetDimensions = integerDimensions(targetSize) else {
            return .failure(.unsupportedTargetDimensions(
                width: safeDimension(targetSize.width),
                height: safeDimension(targetSize.height),
                details: "v4 requires positive integral target dimensions"
            ))
        }
        guard targetDimensions.width >= sourceDimensions.width,
              targetDimensions.height >= sourceDimensions.height else {
            return .failure(.unsupportedScaleFactor(
                details: "the v4 product route is an upscaler on both axes"
            ))
        }
        guard targetDimensions.width <= 32_768,
              targetDimensions.height <= 32_768 else {
            return .failure(.unsupportedTargetDimensions(
                width: targetDimensions.width,
                height: targetDimensions.height,
                details: "the canonical v4 executor limit is 32768 per axis"
            ))
        }
        guard let isFullRange = source.color.isFullRange else {
            return .failure(.unsupportedPixelFormatOrBitDepth(
                details: "v4 requires an explicit video/full range contract"
            ))
        }
        guard source.color.dynamicRange != .unknown else {
            return .failure(.unsupportedPixelFormatOrBitDepth(
                details: "v4 requires an explicit SDR or HDR transfer contract"
            ))
        }

        let bitDepth = source.color.bitDepth
            ?? (source.color.dynamicRange == .hdr ? 10 : 8)
        let storage: PixelStorageV4
        switch (bitDepth, isFullRange) {
        case (8, false): storage = .nv12VideoRange8Bit
        case (8, true): storage = .nv12FullRange8Bit
        case (10, false): storage = .p010VideoRange10Bit
        case (10, true): storage = .p010FullRange10Bit
        default:
            return .failure(.unsupportedPixelFormatOrBitDepth(
                details: "v4 supports native 8-bit NV12 and 10-bit P010; "
                    + "the source reports \(bitDepth)-bit video"
            ))
        }
        if source.color.dynamicRange == .hdr, storage.signalBitDepth != 10 {
            return .failure(.hdrPreservationUnavailable)
        }
        if let reported = source.color.pixelFormat,
           reported != storage.pixelFormat {
            return .failure(.unsupportedPixelFormatOrBitDepth(
                details: "the reported pixel format "
                    + "\(FourCC.string(from: reported) ?? String(reported)) "
                    + "conflicts with the declared depth/range contract"
            ))
        }

        let scanMode: DeterministicScanModeV4
        switch source.color.fieldCount ?? 1 {
        case 1:
            guard source.color.fieldDetail == nil else {
                return .failure(.unsupportedPixelFormatOrBitDepth(
                    details: "a one-field source carries contradictory field detail"
                ))
            }
            scanMode = .progressive
        case 2:
            guard let fieldDetail = source.color.fieldDetail else {
                return .failure(.unsupportedPixelFormatOrBitDepth(
                    details: "interlaced v4 input requires explicit field dominance"
                ))
            }
            let topFirst = kCVImageBufferFieldDetailTemporalTopFirst
                as String
            let topFirst2 = kCVImageBufferFieldDetailSpatialFirstLineEarly
                as String
            let bottomFirst = kCVImageBufferFieldDetailTemporalBottomFirst
                as String
            let bottomFirst2 = kCVImageBufferFieldDetailSpatialFirstLineLate
                as String
            let dominance: FieldDominanceV4
            if fieldDetail == topFirst || fieldDetail == topFirst2 {
                dominance = .topFieldFirst
            } else if fieldDetail == bottomFirst
                || fieldDetail == bottomFirst2 {
                dominance = .bottomFieldFirst
            } else {
                return .failure(.unsupportedPixelFormatOrBitDepth(
                    details: "unsupported interlaced field detail \(fieldDetail)"
                ))
            }
            scanMode = .interlaced(dominance)
        default:
            return .failure(.unsupportedPixelFormatOrBitDepth(
                details: "v4 accepts one progressive frame or two interlaced fields"
            ))
        }

        return .success(DeterministicPreparedConfigurationV4(
            backendID: backendID,
            executionBackend: executionBackend,
            storage: storage,
            sourceWidth: sourceDimensions.width,
            sourceHeight: sourceDimensions.height,
            targetWidth: targetDimensions.width,
            targetHeight: targetDimensions.height,
            scanMode: scanMode
        ))
    }

    private static func integerDimensions(
        _ size: CGSize
    ) -> (width: Int, height: Int)? {
        guard size.width.isFinite,
              size.height.isFinite,
              let width = Int(exactly: size.width),
              let height = Int(exactly: size.height),
              width > 0,
              height > 0 else {
            return nil
        }
        return (width, height)
    }

    private static func safeDimension(_ value: CGFloat) -> Int {
        guard value.isFinite,
              let result = Int(exactly: value.rounded()) else {
            return 0
        }
        return result
    }
}

enum ASHP06MetalLibraryFactoryV4 {
    static func makeLibrary(
        runtime: ASHVerifiedRuntimeBundleV4,
        device: MTLDevice
    ) throws -> MTLLibrary {
        try runtime.verifyBinding()
        let bytes = runtime.artifactData(for: .metalLibrary)
        do {
            return try device.makeLibrary(
                data: bytes.withUnsafeBytes { DispatchData(bytes: $0) }
            )
        } catch {
            throw ASHP06RuntimeProviderV4Error.metalLibraryLoadFailed(
                String(describing: error)
            )
        }
    }
}
