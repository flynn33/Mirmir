import CoreVideo
import Foundation

enum R13ProductASHAnalysisError: Error, Equatable, Sendable {
    case unsupportedPixelFormat(OSType)
    case invalidPlaneLayout
    case unavailablePlaneStorage
}

struct R13ProductASHResourceSnapshot: Equatable, Sendable {
    let backendAvailability: R06ASHBackendAvailability
    let modelReadiness: R06ASHModelReadiness
    let backendQualityConfidenceQ16: R06ASHQ16
    let memoryPressureQ16: R06ASHQ16
    let thermalPressureQ16: R06ASHQ16
    let throughputPressureQ16: R06ASHQ16

    static let nominal = R13ProductASHResourceSnapshot(
        backendAvailability: .available,
        modelReadiness: .notRequired,
        backendQualityConfidenceQ16: .one,
        memoryPressureQ16: .zero,
        thermalPressureQ16: .zero,
        throughputPressureQ16: .zero
    )
}

struct R13ProductASHFrameAnalysis: Equatable, Sendable {
    let featureState: ASHState
    let decisionContext: ASHDecisionContext
}

struct R13ProductASHScaleContext: Equatable, Sendable {
    let routeID: String
    let scaleNumerator: Int
    let scaleDenominator: Int

    init(route: R03ScaleRoute) {
        routeID = route.rawValue
        scaleNumerator = route.scaleNumerator
        scaleDenominator = route.scaleDenominator
    }

    init(
        adaptivePlan: R13AdaptiveScalePlan,
        routeID: String
    ) {
        let numerator = adaptivePlan.targetResolution.width
        let denominator =
            adaptivePlan.processingSourceResolution.width
        let divisor = Self.greatestCommonDivisor(
            numerator,
            denominator
        )
        self.routeID = routeID
        scaleNumerator = numerator / divisor
        scaleDenominator = denominator / divisor
    }

    private static func greatestCommonDivisor(
        _ lhs: Int,
        _ rhs: Int
    ) -> Int {
        var larger = max(lhs, rhs)
        var smaller = min(lhs, rhs)
        while smaller != 0 {
            let remainder = larger % smaller
            larger = smaller
            smaller = remainder
        }
        return max(larger, 1)
    }
}

struct R13ProductASHPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

/// Produces the content sidecar consumed by the shipping ASH router.
///
/// The analyzer deliberately operates on a bounded luma/chroma proxy. The
/// canonical ASH feature extractor and binarizer remain responsible for the
/// numerical feature/state contract; this type only bridges an NV12 frame into
/// that contract and constructs an exact affine ASH transition.
actor R13ProductASHAnalyzer {
    private enum Policy {
        static let proxyWidth = 32
        static let proxyHeight = 18
        static let sceneCutNoiseFloor = 0.08
        static let sceneCutFullScale = 0.40
        static let temporalSupportFullScale = 0.20
    }

    private var previousProxy: ASHImage?
    private var previousFeatureState = ASHState(validatedRawValue: 0)
    private var previousDecisionState = ASHState(validatedRawValue: 0)
    private var shotOrdinal = 0

    func reset() {
        previousProxy = nil
        previousFeatureState = ASHState(validatedRawValue: 0)
        previousDecisionState = ASHState(validatedRawValue: 0)
        shotOrdinal = 0
    }

    func analyze(
        pixelBuffer: R13ProductASHPixelBuffer,
        frameIdentifier: String,
        streamIdentifier: String,
        route: R03ScaleRoute,
        dwellFrames: Int,
        currentBackendID: String?,
        previousBackendID: String?,
        processingConfiguration: UpscaleProcessingConfiguration,
        resources: R13ProductASHResourceSnapshot,
        fallbackReason: R06ASHFallbackReason? = nil
    ) throws -> R13ProductASHFrameAnalysis {
        try analyze(
            pixelBuffer: pixelBuffer,
            frameIdentifier: frameIdentifier,
            streamIdentifier: streamIdentifier,
            scale: R13ProductASHScaleContext(route: route),
            dwellFrames: dwellFrames,
            currentBackendID: currentBackendID,
            previousBackendID: previousBackendID,
            processingConfiguration: processingConfiguration,
            resources: resources,
            fallbackReason: fallbackReason
        )
    }

    func analyze(
        pixelBuffer: R13ProductASHPixelBuffer,
        frameIdentifier: String,
        streamIdentifier: String,
        scale: R13ProductASHScaleContext,
        dwellFrames: Int,
        currentBackendID: String?,
        previousBackendID: String?,
        processingConfiguration: UpscaleProcessingConfiguration,
        resources: R13ProductASHResourceSnapshot,
        fallbackReason: R06ASHFallbackReason? = nil
    ) throws -> R13ProductASHFrameAnalysis {
        let proxy = try Self.makeProxy(pixelBuffer.value)
        let features = try ASHFeatureExtractor.extract(
            current: proxy.image,
            previous: previousProxy,
            chromaEnergy: proxy.chromaEnergy
        )
        let featureState = try ASHFeatureBinarizer.binarize(
            features,
            previousState: previousFeatureState
        )
        let transition = Self.closestExactTransition(
            from: previousDecisionState,
            toward: featureState
        )
        let temporalChange = features.values[7]
        let sceneCutConfidence = Self.sceneCutConfidence(
            temporalChange: temporalChange,
            hasHistory: previousProxy != nil
        )
        if sceneCutConfidence.rawValue
            >= R06ASHParameters.frozen.thresholds
                .sceneCutConfidenceQ16 {
            shotOrdinal += 1
        }

        let context = ASHDecisionContext(
            identity: try R06ASHIdentityContext(
                frameID: frameIdentifier,
                shotID: "\(streamIdentifier).shot.\(shotOrdinal)",
                routeID: scale.routeID,
                scaleNumerator: scale.scaleNumerator,
                scaleDenominator: scale.scaleDenominator,
                planeLayout: proxy.planeLayout,
                chromaSiting: .left
            ),
            state: try R06ASHStateContext(
                continuousFeatureValuesQ16:
                    features.values.map(Self.q16),
                currentState: transition.currentState,
                previousState: previousDecisionState,
                stateTransition: R06ASHStateTransition(
                    previousState: previousDecisionState,
                    currentState: transition.currentState
                ),
                dwellFrames: max(dwellFrames, 0)
            ),
            signals: R06ASHSignalContext(
                sceneCutConfidenceQ16: sceneCutConfidence,
                motionConfidenceQ16: Self.temporalSupportConfidence(
                    temporalChange: temporalChange,
                    hasHistory: previousProxy != nil
                ),
                occlusionConfidenceQ16: .zero,
                noiseEstimateQ16: Self.q16(features.values[3]),
                blurEstimateQ16: .zero,
                compressionEstimateQ16: .zero,
                aliasingEstimateQ16: Self.q16(features.values[2])
            ),
            protection: R06ASHProtectionContext(
                faceOccupancyQ15: .zero,
                textOccupancyQ15: .zero,
                lineArtOccupancyQ15: .zero,
                animationOccupancyQ15: .zero,
                uiOccupancyQ15: .zero
            ),
            resources: R06ASHResourceContext(
                backendAvailability: resources.backendAvailability,
                modelReadiness: resources.modelReadiness,
                backendQualityConfidenceQ16:
                    resources.backendQualityConfidenceQ16,
                memoryPressureQ16: resources.memoryPressureQ16,
                thermalPressureQ16: resources.thermalPressureQ16,
                throughputPressureQ16:
                    resources.throughputPressureQ16
            ),
            backendHistory: try R06ASHBackendHistory(
                currentBackendID: currentBackendID,
                previousBackendID: previousBackendID
            ),
            effects: R06ASHEffectContext(
                preprocessStrengthQ16: Self.q16(
                    processingConfiguration.detailRecoveryLevel
                        .normalizedStrength
                ),
                postprocessStrengthQ16: Self.q16(
                    processingConfiguration.edgeFidelityLevel
                        .normalizedStrength
                ),
                artifactRiskQ16: Self.q16(
                    max(features.values[2], features.values[3])
                )
            ),
            outcome: R06ASHOutcomeContext(
                postflightFindings: try R06ASHPostflightFindings(
                    riskQ16: .zero,
                    findings: []
                ),
                fallbackReason: fallbackReason,
                retryEligibility: .eligible
            )
        )

        previousProxy = proxy.image
        previousFeatureState = featureState
        previousDecisionState = transition.currentState
        return R13ProductASHFrameAnalysis(
            featureState: featureState,
            decisionContext: context
        )
    }

    private static func closestExactTransition(
        from previous: ASHState,
        toward desired: ASHState
    ) -> (message: ASHMessage, currentState: ASHState) {
        let desiredDelta = previous.xor(desired)
        let selected = ASHCode.messageCodewordPairs.min { lhs, rhs in
            let lhsDistance = lhs.codeword.hammingDistance(
                to: desiredDelta
            )
            let rhsDistance = rhs.codeword.hammingDistance(
                to: desiredDelta
            )
            return lhsDistance == rhsDistance
                ? lhs.message.rawValue < rhs.message.rawValue
                : lhsDistance < rhsDistance
        }
        guard let selected else {
            preconditionFailure(
                "The canonical ASH code must retain all sixteen messages."
            )
        }
        return (
            selected.message,
            previous.xor(selected.codeword)
        )
    }

    private static func sceneCutConfidence(
        temporalChange: Double,
        hasHistory: Bool
    ) -> R06ASHQ16 {
        guard hasHistory else { return .zero }
        let span =
            Policy.sceneCutFullScale - Policy.sceneCutNoiseFloor
        return q16(
            (temporalChange - Policy.sceneCutNoiseFloor) / span
        )
    }

    private static func temporalSupportConfidence(
        temporalChange: Double,
        hasHistory: Bool
    ) -> R06ASHQ16 {
        guard hasHistory else { return .zero }
        return q16(
            1.0 - (temporalChange / Policy.temporalSupportFullScale)
        )
    }

    private static func q16(_ value: Double) -> R06ASHQ16 {
        let unitValue = min(max(value, 0.0), 1.0)
        return R06ASHQ16(
            validatedRawValue: Int64(
                (unitValue * Double(R06ASHQ16.scale)).rounded()
            )
        )
    }

    private static func makeProxy(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> (
        image: ASHImage,
        chromaEnergy: Double,
        planeLayout: R06ASHPlaneLayout
    ) {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            let proxy = try makeBiPlanarProxy(
                pixelBuffer,
                wordStorage: false
            )
            return (
                proxy.image,
                proxy.chromaEnergy,
                .nv12
            )
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            let proxy = try makeBiPlanarProxy(
                pixelBuffer,
                wordStorage: true
            )
            return (
                proxy.image,
                proxy.chromaEnergy,
                .p010
            )
        case kCVPixelFormatType_32BGRA:
            let proxy = try makeBGRAProxy(pixelBuffer)
            return (
                proxy.image,
                proxy.chromaEnergy,
                .bgra
            )
        default:
            let layout: R13PixelLayout
            do {
                layout = try R13PixelLayoutRegistry.layout(
                    for: pixelFormat
                )
            } catch {
                throw R13ProductASHAnalysisError
                    .unsupportedPixelFormat(pixelFormat)
            }
            let proxy = try makeLayoutProxy(
                pixelBuffer,
                layout: layout
            )
            return (
                proxy.image,
                proxy.chromaEnergy,
                try analysisPlaneLayout(layout)
            )
        }
    }

    private static func analysisPlaneLayout(
        _ layout: R13PixelLayout
    ) throws -> R06ASHPlaneLayout {
        let firstPlane = layout.planes[0]
        if firstPlane.role == .packedAYCbCr {
            return firstPlane.bytesPerComponent == 1
                ? .aycbcrPacked8Alpha
                : .aycbcrPacked16Alpha
        }
        if layout.planes.contains(where: { $0.role == .alpha }) {
            return .yuv444TriPlanar16Alpha
        }
        guard let chroma = layout.planes.first(
            where: { $0.role == .interleavedChroma }
        ) else {
            throw R13ProductASHAnalysisError.invalidPlaneLayout
        }
        let depth =
            firstPlane.bytesPerComponent == 1
            ? 8
            : (firstPlane.storedCodeShift == 6 ? 10 : 16)
        if chroma.widthDivisor == 2,
           chroma.heightDivisor == 2 {
            switch depth {
            case 8:
                return .nv12
            case 10:
                return .p010
            default:
                throw R13ProductASHAnalysisError.invalidPlaneLayout
            }
        }
        if chroma.widthDivisor == 2,
           chroma.heightDivisor == 1 {
            switch depth {
            case 8:
                return .yuv422BiPlanar8
            case 10:
                return .yuv422BiPlanar10
            case 16:
                return .yuv422BiPlanar16
            default:
                throw R13ProductASHAnalysisError.invalidPlaneLayout
            }
        }
        if chroma.widthDivisor == 1,
           chroma.heightDivisor == 1 {
            switch depth {
            case 8:
                return .yuv444BiPlanar8
            case 10:
                return .yuv444BiPlanar10
            case 16:
                return .yuv444BiPlanar16
            default:
                throw R13ProductASHAnalysisError.invalidPlaneLayout
            }
        }
        throw R13ProductASHAnalysisError.invalidPlaneLayout
    }

    private static func makeBiPlanarProxy(
        _ pixelBuffer: CVPixelBuffer,
        wordStorage: Bool
    ) throws -> (image: ASHImage, chromaEnergy: Double) {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw R13ProductASHAnalysisError.invalidPlaneLayout
        }
        let status = CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        )
        guard status == kCVReturnSuccess else {
            throw R13ProductASHAnalysisError.unavailablePlaneStorage
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(
                  pixelBuffer,
                  0
              ),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(
                  pixelBuffer,
                  1
              ) else {
            throw R13ProductASHAnalysisError.unavailablePlaneStorage
        }
        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            0
        )
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(
            pixelBuffer,
            1
        )
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            1
        )
        let bytesPerComponent = wordStorage ? 2 : 1
        guard lumaWidth > 0,
              lumaHeight > 0,
              lumaStride >= lumaWidth * bytesPerComponent,
              chromaWidth > 0,
              chromaHeight > 0,
              chromaStride
                >= chromaWidth * 2 * bytesPerComponent else {
            throw R13ProductASHAnalysisError.invalidPlaneLayout
        }

        let proxyWidth = min(Policy.proxyWidth, lumaWidth)
        let proxyHeight = min(Policy.proxyHeight, lumaHeight)
        var lumaValues: [Double] = []
        lumaValues.reserveCapacity(proxyWidth * proxyHeight)
        for row in 0..<proxyHeight {
            let sourceRow = centeredSampleIndex(
                row,
                sampleCount: proxyHeight,
                sourceCount: lumaHeight
            )
            for column in 0..<proxyWidth {
                let sourceColumn = centeredSampleIndex(
                    column,
                    sampleCount: proxyWidth,
                    sourceCount: lumaWidth
                )
                lumaValues.append(
                    normalizedLuma(
                        base: lumaBase,
                        stride: lumaStride,
                        row: sourceRow,
                        component: sourceColumn,
                        wordStorage: wordStorage
                    )
                )
            }
        }

        let chromaSampleWidth = min(Policy.proxyWidth, chromaWidth)
        let chromaSampleHeight = min(
            Policy.proxyHeight,
            chromaHeight
        )
        var chromaTotal = 0.0
        for row in 0..<chromaSampleHeight {
            let sourceRow = centeredSampleIndex(
                row,
                sampleCount: chromaSampleHeight,
                sourceCount: chromaHeight
            )
            for column in 0..<chromaSampleWidth {
                let sourceColumn = centeredSampleIndex(
                    column,
                    sampleCount: chromaSampleWidth,
                    sourceCount: chromaWidth
                )
                chromaTotal += normalizedChromaEnergy(
                    base: chromaBase,
                    stride: chromaStride,
                    row: sourceRow,
                    componentPair: sourceColumn,
                    wordStorage: wordStorage
                )
            }
        }
        let chromaCount = chromaSampleWidth * chromaSampleHeight
        return (
            try ASHImage(
                width: proxyWidth,
                height: proxyHeight,
                channels: 1,
                values: lumaValues
            ),
            chromaCount > 0
                ? min(max(chromaTotal / Double(chromaCount), 0.0), 1.0)
                : 0.0
        )
    }

    private static func normalizedLuma(
        base: UnsafeMutableRawPointer,
        stride: Int,
        row: Int,
        component: Int,
        wordStorage: Bool
    ) -> Double {
        let code: Double
        let minimum: Double
        let span: Double
        if wordStorage {
            let words = base
                .advanced(by: row * stride)
                .assumingMemoryBound(to: UInt16.self)
            code = Double(words[component] >> 6)
            minimum = 64.0
            span = 876.0
        } else {
            let bytes = base
                .advanced(by: row * stride)
                .assumingMemoryBound(to: UInt8.self)
            code = Double(bytes[component])
            minimum = 16.0
            span = 219.0
        }
        return min(max((code - minimum) / span, 0.0), 1.0)
    }

    private static func normalizedChromaEnergy(
        base: UnsafeMutableRawPointer,
        stride: Int,
        row: Int,
        componentPair: Int,
        wordStorage: Bool
    ) -> Double {
        if wordStorage {
            let words = base
                .advanced(by: row * stride)
                .assumingMemoryBound(to: UInt16.self)
            let offset = componentPair * 2
            return min(
                (
                    abs(Double(words[offset] >> 6) - 512.0)
                    + abs(Double(words[offset + 1] >> 6) - 512.0)
                ) / 896.0,
                1.0
            )
        }
        let bytes = base
            .advanced(by: row * stride)
            .assumingMemoryBound(to: UInt8.self)
        let offset = componentPair * 2
        return min(
            (
                abs(Double(bytes[offset]) - 128.0)
                + abs(Double(bytes[offset + 1]) - 128.0)
            ) / 254.0,
            1.0
        )
    }

    private static func makeBGRAProxy(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> (image: ASHImage, chromaEnergy: Double) {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 0 else {
            throw R13ProductASHAnalysisError.invalidPlaneLayout
        }
        let status = CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        )
        guard status == kCVReturnSuccess else {
            throw R13ProductASHAnalysisError.unavailablePlaneStorage
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw R13ProductASHAnalysisError.unavailablePlaneStorage
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0,
              height > 0,
              stride >= width * 4 else {
            throw R13ProductASHAnalysisError.invalidPlaneLayout
        }
        let proxyWidth = min(Policy.proxyWidth, width)
        let proxyHeight = min(Policy.proxyHeight, height)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var lumaValues: [Double] = []
        lumaValues.reserveCapacity(proxyWidth * proxyHeight)
        var chromaTotal = 0.0
        for row in 0..<proxyHeight {
            let sourceRow = centeredSampleIndex(
                row,
                sampleCount: proxyHeight,
                sourceCount: height
            )
            for column in 0..<proxyWidth {
                let sourceColumn = centeredSampleIndex(
                    column,
                    sampleCount: proxyWidth,
                    sourceCount: width
                )
                let offset = sourceRow * stride + sourceColumn * 4
                let blue = Double(bytes[offset]) / 255.0
                let green = Double(bytes[offset + 1]) / 255.0
                let red = Double(bytes[offset + 2]) / 255.0
                lumaValues.append(
                    0.0722 * blue
                        + 0.7152 * green
                        + 0.2126 * red
                )
                chromaTotal +=
                    max(red, max(green, blue))
                    - min(red, min(green, blue))
            }
        }
        let sampleCount = proxyWidth * proxyHeight
        return (
            try ASHImage(
                width: proxyWidth,
                height: proxyHeight,
                channels: 1,
                values: lumaValues
            ),
            sampleCount > 0
                ? min(
                    max(chromaTotal / Double(sampleCount), 0.0),
                    1.0
                )
                : 0.0
        )
    }

    private static func makeLayoutProxy(
        _ pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout
    ) throws -> (image: ASHImage, chromaEnergy: Double) {
        do {
            try layout.validate(pixelBuffer)
        } catch {
            throw R13ProductASHAnalysisError.invalidPlaneLayout
        }
        let status = CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        )
        guard status == kCVReturnSuccess else {
            throw R13ProductASHAnalysisError.unavailablePlaneStorage
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let proxyWidth = min(Policy.proxyWidth, width)
        let proxyHeight = min(Policy.proxyHeight, height)
        guard proxyWidth > 0, proxyHeight > 0 else {
            throw R13ProductASHAnalysisError.invalidPlaneLayout
        }
        var lumaValues: [Double] = []
        lumaValues.reserveCapacity(proxyWidth * proxyHeight)
        var chromaTotal = 0.0
        do {
            for row in 0..<proxyHeight {
                let sourceRow = centeredSampleIndex(
                    row,
                    sampleCount: proxyHeight,
                    sourceCount: height
                )
                for column in 0..<proxyWidth {
                    let sourceColumn = centeredSampleIndex(
                        column,
                        sampleCount: proxyWidth,
                        sourceCount: width
                    )
                    lumaValues.append(
                        try R13PixelLayoutProcessor
                            .normalizedLumaLocked(
                                pixelBuffer,
                                column: sourceColumn,
                                row: sourceRow,
                                layout: layout
                            )
                    )
                    chromaTotal +=
                        try R13PixelLayoutProcessor
                            .normalizedChromaEnergyLocked(
                                pixelBuffer,
                                column: sourceColumn,
                                row: sourceRow,
                                layout: layout
                            )
                }
            }
        } catch {
            throw R13ProductASHAnalysisError.unavailablePlaneStorage
        }
        let sampleCount = proxyWidth * proxyHeight
        return (
            try ASHImage(
                width: proxyWidth,
                height: proxyHeight,
                channels: 1,
                values: lumaValues
            ),
            min(
                max(chromaTotal / Double(sampleCount), 0),
                1
            )
        )
    }

    private static func centeredSampleIndex(
        _ index: Int,
        sampleCount: Int,
        sourceCount: Int
    ) -> Int {
        let numerator =
            (Int64(index) * 2 + 1) * Int64(sourceCount)
        let denominator = Int64(sampleCount) * 2
        return min(
            Int(numerator / denominator),
            sourceCount - 1
        )
    }
}

private extension MirmirAdjustmentLevel {
    var normalizedStrength: Double {
        switch self {
        case .low:
            return 0.25
        case .medium:
            return 0.5
        case .high:
            return 0.75
        }
    }
}
