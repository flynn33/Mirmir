import CryptoKit
import Darwin
import Foundation

@_silgen_name("fcntl")
private func r12FcntlPointer(
    _ descriptor: Int32,
    _ command: Int32,
    _ pointer: UnsafeMutableRawPointer
) -> Int32

// swiftlint:disable file_length

enum R12RouteResolverErrorV2: Error, Equatable, Sendable {
    case invalidIdentity(field: String)
    case invalidSHA256(field: String)
    case invalidScaleFactor(numerator: Int64, denominator: Int64)
    case resolutionOutOfRange(role: String, width: Int, height: Int)
    case invalidResolutionRange(axis: String, minimum: Int, maximum: Int)
    case invalidResolutionAlignment(axis: String, alignment: Int)
    case unalignedResolutionBoundary(
        axis: String,
        boundary: String,
        value: Int,
        alignment: Int
    )
    case nonUniformScale(
        widthNumerator: Int64,
        widthDenominator: Int64,
        heightNumerator: Int64,
        heightDenominator: Int64
    )
    case invalidPreferenceOrdinal(routeID: String, ordinal: Int)
    case emptyScaleFactors(routeID: String)
    case duplicateScaleFactor(routeID: String, numerator: Int64, denominator: Int64)
    case emptyFormatTransitions(routeID: String)
    case duplicateFormatTransition(routeID: String)
    case backendFormatMismatch(routeID: String, contractSHA256: String)
    case nativeRouteRequiresNativeEvidence(routeID: String)
    case nativeEvidenceMismatch(routeID: String)
    case duplicateHardwareRoute(String)
    case duplicateCandidateRoute(String)
    case duplicateNativeObservation(String)
    case nativeObservationForDeterministicRoute(String)
    case nativeObservationForUnknownRoute(String)
    case nativeReceiptDigestMismatch(expected: String, actual: String)
    case nativeReceiptNotCanonical
    case nativeReceiptSchemaMismatch
    case unsafeNativeReceiptFile(String)
    case nativeReceiptFileChanged(String)
    case nativeReceiptTooLarge(maximumSize: Int)
    case nativeReceiptReadFailed(String)
}

struct R12ExactScaleFactorV2: Hashable, Sendable, CustomStringConvertible {
    let numerator: Int64
    let denominator: Int64

    init(numerator: Int64, denominator: Int64) throws {
        guard numerator > 0, denominator > 0 else {
            throw R12RouteResolverErrorV2.invalidScaleFactor(
                numerator: numerator,
                denominator: denominator
            )
        }
        let divisor = Self.greatestCommonDivisor(numerator, denominator)
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    var description: String {
        "\(numerator)/\(denominator)"
    }

    static func derive(
        source: R12ResolutionV2,
        target: R12ResolutionV2
    ) throws -> R12ExactScaleFactorV2 {
        guard let sourceWidth = Int64(exactly: source.width),
              let sourceHeight = Int64(exactly: source.height),
              let targetWidth = Int64(exactly: target.width),
              let targetHeight = Int64(exactly: target.height) else {
            throw R12RouteResolverErrorV2.resolutionOutOfRange(
                role: "source_or_target",
                width: target.width,
                height: target.height
            )
        }
        let widthScale = try R12ExactScaleFactorV2(
            numerator: targetWidth,
            denominator: sourceWidth
        )
        let heightScale = try R12ExactScaleFactorV2(
            numerator: targetHeight,
            denominator: sourceHeight
        )
        guard widthScale == heightScale else {
            throw R12RouteResolverErrorV2.nonUniformScale(
                widthNumerator: widthScale.numerator,
                widthDenominator: widthScale.denominator,
                heightNumerator: heightScale.numerator,
                heightDenominator: heightScale.denominator
            )
        }
        return widthScale
    }

    private static func greatestCommonDivisor(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        var first = lhs
        var second = rhs
        while second != 0 {
            (first, second) = (second, first % second)
        }
        return first
    }
}

struct R12RouteResolutionBoundsV2: Hashable, Sendable {
    let minimumWidth: Int
    let maximumWidth: Int
    let minimumHeight: Int
    let maximumHeight: Int
    let widthAlignment: Int
    let heightAlignment: Int

    init(
        minimumWidth: Int,
        maximumWidth: Int,
        minimumHeight: Int,
        maximumHeight: Int,
        widthAlignment: Int,
        heightAlignment: Int
    ) throws {
        try Self.validateRange(
            axis: "width",
            minimum: minimumWidth,
            maximum: maximumWidth
        )
        try Self.validateRange(
            axis: "height",
            minimum: minimumHeight,
            maximum: maximumHeight
        )
        try Self.validateAlignment(axis: "width", alignment: widthAlignment)
        try Self.validateAlignment(axis: "height", alignment: heightAlignment)
        try Self.validateBoundary(
            axis: "width",
            boundary: "minimum",
            value: minimumWidth,
            alignment: widthAlignment
        )
        try Self.validateBoundary(
            axis: "width",
            boundary: "maximum",
            value: maximumWidth,
            alignment: widthAlignment
        )
        try Self.validateBoundary(
            axis: "height",
            boundary: "minimum",
            value: minimumHeight,
            alignment: heightAlignment
        )
        try Self.validateBoundary(
            axis: "height",
            boundary: "maximum",
            value: maximumHeight,
            alignment: heightAlignment
        )
        self.minimumWidth = minimumWidth
        self.maximumWidth = maximumWidth
        self.minimumHeight = minimumHeight
        self.maximumHeight = maximumHeight
        self.widthAlignment = widthAlignment
        self.heightAlignment = heightAlignment
    }

    func supports(_ resolution: R12ResolutionV2) -> Bool {
        (minimumWidth...maximumWidth).contains(resolution.width)
            && (minimumHeight...maximumHeight).contains(resolution.height)
            && resolution.width.isMultiple(of: widthAlignment)
            && resolution.height.isMultiple(of: heightAlignment)
    }

    private static func validateRange(
        axis: String,
        minimum: Int,
        maximum: Int
    ) throws {
        guard minimum > 0, maximum >= minimum else {
            throw R12RouteResolverErrorV2.invalidResolutionRange(
                axis: axis,
                minimum: minimum,
                maximum: maximum
            )
        }
    }

    private static func validateAlignment(
        axis: String,
        alignment: Int
    ) throws {
        guard alignment > 0 else {
            throw R12RouteResolverErrorV2.invalidResolutionAlignment(
                axis: axis,
                alignment: alignment
            )
        }
    }

    private static func validateBoundary(
        axis: String,
        boundary: String,
        value: Int,
        alignment: Int
    ) throws {
        guard value.isMultiple(of: alignment) else {
            throw R12RouteResolverErrorV2.unalignedResolutionBoundary(
                axis: axis,
                boundary: boundary,
                value: value,
                alignment: alignment
            )
        }
    }
}

enum R12RouteExecutionRequirementV2: String, Hashable, Sendable {
    case deterministicContract = "deterministic_contract"
    case nativeObserved = "native_observed"
}

enum R12RouteSelectionAuthorityV2: String, Hashable, Sendable {
    case softwareFunctionOnly = "software_function_only"
}

struct R12HardwareTierIdentityV2: Hashable, Sendable {
    static let deterministicFixture = makeStatic("deterministic_fixture")
    static let appleSiliconNative = makeStatic("apple_silicon_native")

    let rawValue: String

    init(_ rawValue: String) throws {
        self.rawValue = try R12RouteResolverValidationV2.identity(
            rawValue,
            field: "hardware_tier_id"
        )
    }

    private static func makeStatic(_ value: String) -> R12HardwareTierIdentityV2 {
        do {
            return try R12HardwareTierIdentityV2(value)
        } catch {
            preconditionFailure("Invalid static R12 hardware tier: \(error)")
        }
    }
}

struct R12HostIdentityV2: Hashable, Sendable {
    let hostID: String
    let modelIdentifier: String
    let chipIdentity: String

    init(
        hostID: String,
        modelIdentifier: String,
        chipIdentity: String
    ) throws {
        self.hostID = try R12RouteResolverValidationV2.identity(
            hostID,
            field: "host_id"
        )
        self.modelIdentifier = try R12RouteResolverValidationV2.identity(
            modelIdentifier,
            field: "model_identifier"
        )
        self.chipIdentity = try R12RouteResolverValidationV2.identity(
            chipIdentity,
            field: "chip_identity"
        )
    }
}

enum R12HardwareExecutionContextV2: Hashable, Sendable {
    case deterministicFixture
    case nativeHost(R12HostIdentityV2)
}

struct R12HardwareCapabilityProfileV2: Hashable, Sendable {
    let profileID: String
    let tierIdentity: R12HardwareTierIdentityV2
    let executionContext: R12HardwareExecutionContextV2
    let availableRouteIDs: [String]

    init(
        profileID: String,
        tierIdentity: R12HardwareTierIdentityV2,
        executionContext: R12HardwareExecutionContextV2,
        availableRouteIDs: [String]
    ) throws {
        var routeIDs: Set<String> = []
        for routeID in availableRouteIDs {
            let validated = try R12RouteResolverValidationV2.identity(
                routeID,
                field: "available_route_id"
            )
            guard routeIDs.insert(validated).inserted else {
                throw R12RouteResolverErrorV2.duplicateHardwareRoute(validated)
            }
        }
        self.profileID = try R12RouteResolverValidationV2.identity(
            profileID,
            field: "hardware_profile_id"
        )
        self.tierIdentity = tierIdentity
        self.executionContext = executionContext
        self.availableRouteIDs = routeIDs.sorted()
    }

    func declaresAvailable(routeID: String) -> Bool {
        availableRouteIDs.contains(routeID)
    }
}

struct R12RouteFormatTransitionV2: Sendable {
    let input: R12MediaFormatContractV2
    let output: R12MediaFormatContractV2

    var inputContractSHA256: String {
        input.canonicalSHA256
    }

    var outputContractSHA256: String {
        output.canonicalSHA256
    }

    var stableIdentity: String {
        "\(inputContractSHA256)->\(outputContractSHA256)"
    }

    func matches(
        input candidateInput: R12MediaFormatContractV2,
        output candidateOutput: R12MediaFormatContractV2
    ) -> Bool {
        inputContractSHA256 == candidateInput.canonicalSHA256
            && outputContractSHA256 == candidateOutput.canonicalSHA256
    }
}

struct R12RouteCapabilityV2: Sendable {
    let routeID: String
    let preferenceOrdinal: Int
    let backendCapability: R12BackendFormatCapabilityV2
    let sourceResolutionBounds: R12RouteResolutionBoundsV2
    let targetResolutionBounds: R12RouteResolutionBoundsV2
    let supportedScaleFactors: [R12ExactScaleFactorV2]
    let formatTransitions: [R12RouteFormatTransitionV2]
    let executionRequirement: R12RouteExecutionRequirementV2
    let nativeObservationSHA256: String?

    init(
        routeID: String,
        preferenceOrdinal: Int,
        backendCapability: R12BackendFormatCapabilityV2,
        sourceResolutionBounds: R12RouteResolutionBoundsV2,
        targetResolutionBounds: R12RouteResolutionBoundsV2,
        supportedScaleFactors: [R12ExactScaleFactorV2],
        formatTransitions: [R12RouteFormatTransitionV2],
        executionRequirement: R12RouteExecutionRequirementV2
    ) throws {
        let routeID = try R12RouteResolverValidationV2.identity(
            routeID,
            field: "route_id"
        )
        guard preferenceOrdinal >= 0 else {
            throw R12RouteResolverErrorV2.invalidPreferenceOrdinal(
                routeID: routeID,
                ordinal: preferenceOrdinal
            )
        }
        guard !supportedScaleFactors.isEmpty else {
            throw R12RouteResolverErrorV2.emptyScaleFactors(routeID: routeID)
        }
        var scaleFactors: Set<R12ExactScaleFactorV2> = []
        for scaleFactor in supportedScaleFactors {
            guard scaleFactors.insert(scaleFactor).inserted else {
                throw R12RouteResolverErrorV2.duplicateScaleFactor(
                    routeID: routeID,
                    numerator: scaleFactor.numerator,
                    denominator: scaleFactor.denominator
                )
            }
        }
        guard !formatTransitions.isEmpty else {
            throw R12RouteResolverErrorV2.emptyFormatTransitions(routeID: routeID)
        }
        var transitionIDs: Set<String> = []
        for transition in formatTransitions {
            guard transitionIDs.insert(transition.stableIdentity).inserted else {
                throw R12RouteResolverErrorV2.duplicateFormatTransition(
                    routeID: routeID
                )
            }
            for contract in [transition.input, transition.output]
            where !backendCapability.supports(contract) {
                throw R12RouteResolverErrorV2.backendFormatMismatch(
                    routeID: routeID,
                    contractSHA256: contract.canonicalSHA256
                )
            }
        }
        let nativeObservationSHA256: String?
        if executionRequirement == .nativeObserved {
            guard backendCapability.evidence.basis == .nativeObserved,
                  formatTransitions.allSatisfy({
                      $0.input.evidence.basis == .nativeObserved
                          && $0.output.evidence.basis == .nativeObserved
                  }) else {
                throw R12RouteResolverErrorV2.nativeRouteRequiresNativeEvidence(
                    routeID: routeID
                )
            }
            let evidenceHashes = [backendCapability.evidence.nativeObservationSHA256]
                + formatTransitions.flatMap {
                    [
                        $0.input.evidence.nativeObservationSHA256,
                        $0.output.evidence.nativeObservationSHA256
                    ]
                }
            guard let firstEvidenceHash = evidenceHashes.compactMap({ $0 }).first,
                  evidenceHashes.allSatisfy({ $0 == firstEvidenceHash }) else {
                throw R12RouteResolverErrorV2.nativeEvidenceMismatch(
                    routeID: routeID
                )
            }
            nativeObservationSHA256 = try R12RouteResolverValidationV2.sha256(
                firstEvidenceHash,
                field: "native_observation_sha256"
            )
        } else {
            nativeObservationSHA256 = nil
        }
        self.routeID = routeID
        self.preferenceOrdinal = preferenceOrdinal
        self.backendCapability = backendCapability
        self.sourceResolutionBounds = sourceResolutionBounds
        self.targetResolutionBounds = targetResolutionBounds
        self.supportedScaleFactors = scaleFactors.sorted {
            if $0.numerator != $1.numerator {
                return $0.numerator < $1.numerator
            }
            return $0.denominator < $1.denominator
        }
        self.formatTransitions = formatTransitions.sorted {
            $0.stableIdentity < $1.stableIdentity
        }
        self.executionRequirement = executionRequirement
        self.nativeObservationSHA256 = nativeObservationSHA256
    }

    func supports(
        sourceResolution: R12ResolutionV2,
        targetResolution: R12ResolutionV2,
        scaleFactor: R12ExactScaleFactorV2,
        input: R12MediaFormatContractV2,
        output: R12MediaFormatContractV2
    ) -> Bool {
        sourceResolutionBounds.supports(sourceResolution)
            && targetResolutionBounds.supports(targetResolution)
            && supportedScaleFactors.contains(scaleFactor)
            && formatTransitions.contains { $0.matches(input: input, output: output) }
    }
}

struct R12RouteRequestV2: Sendable {
    let sourceResolution: R12ResolutionV2
    let targetResolution: R12ResolutionV2
    let inputFormat: R12MediaFormatContractV2
    let outputFormat: R12MediaFormatContractV2
    let hardwareProfile: R12HardwareCapabilityProfileV2
    let scaleFactor: R12ExactScaleFactorV2

    init(
        sourceResolution: R12ResolutionV2,
        targetResolution: R12ResolutionV2,
        inputFormat: R12MediaFormatContractV2,
        outputFormat: R12MediaFormatContractV2,
        hardwareProfile: R12HardwareCapabilityProfileV2
    ) throws {
        try inputFormat.format.validate(resolution: sourceResolution)
        try outputFormat.format.validate(resolution: targetResolution)
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.hardwareProfile = hardwareProfile
        self.scaleFactor = try R12ExactScaleFactorV2.derive(
            source: sourceResolution,
            target: targetResolution
        )
    }
}

enum R12NativeReceiptAuthorityV2: String, Hashable, Sendable {
    case integrityVerifiedObservationNotObserved =
        "integrity_verified_observation_not_observed"
    case trustedExternalObservation = "trusted_external_observation"
}

struct R12NativeRouteObservationV2: Hashable, Sendable {
    static let artifactKind = "r12_native_route_observation_receipt"
    static let schemaVersion = "1.0.0"
    static let maximumReceiptSize = 1_048_576

    private struct ReceiptPathSnapshot {
        let path: String
        let device: dev_t
        let inode: ino_t
        let fileType: mode_t

        init(path: String, status: stat) {
            self.path = path
            self.device = status.st_dev
            self.inode = status.st_ino
            self.fileType = status.st_mode & mode_t(S_IFMT)
        }

        func matches(_ status: stat) -> Bool {
            device == status.st_dev
                && inode == status.st_ino
                && fileType == status.st_mode & mode_t(S_IFMT)
        }
    }

    private struct OpenedReceipt {
        let descriptor: Int32
        let pathSnapshots: [ReceiptPathSnapshot]
    }

    let receiptID: String
    let receiptSHA256: String
    let hostIdentity: R12HostIdentityV2
    let hardwareProfileID: String
    let hardwareTierIdentity: R12HardwareTierIdentityV2
    let routeID: String
    let backendID: String
    let scaleFactor: R12ExactScaleFactorV2
    let inputContractSHA256: String
    let outputContractSHA256: String
    let authority: R12NativeReceiptAuthorityV2

    static func loadCanonicalReceipt(
        _ canonicalReceiptBytes: Data,
        expectedSHA256: String
    ) throws -> R12NativeRouteObservationV2 {
        let expectedSHA256 = try R12RouteResolverValidationV2.sha256(
            expectedSHA256,
            field: "expected_receipt_sha256"
        )
        let actualSHA256 = R12RouteResolverValidationV2.sha256(
            canonicalReceiptBytes
        )
        guard actualSHA256 == expectedSHA256 else {
            throw R12RouteResolverErrorV2.nativeReceiptDigestMismatch(
                expected: expectedSHA256,
                actual: actualSHA256
            )
        }
        let document: R12NativeRouteReceiptDocumentV2
        do {
            document = try JSONDecoder().decode(
                R12NativeRouteReceiptDocumentV2.self,
                from: canonicalReceiptBytes
            )
        } catch {
            throw R12RouteResolverErrorV2.nativeReceiptNotCanonical
        }
        guard document.artifactKind == artifactKind,
              document.schemaVersion == schemaVersion else {
            throw R12RouteResolverErrorV2.nativeReceiptSchemaMismatch
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(document) == canonicalReceiptBytes else {
            throw R12RouteResolverErrorV2.nativeReceiptNotCanonical
        }
        return try R12NativeRouteObservationV2(
            document: document,
            receiptSHA256: actualSHA256
        )
    }

    static func loadCanonicalReceipt(
        at url: URL,
        expectedSHA256: String
    ) throws -> R12NativeRouteObservationV2 {
        try loadCanonicalReceipt(
            at: url,
            expectedSHA256: expectedSHA256,
            afterOpen: nil
        )
    }

    #if DEBUG
    static func loadCanonicalReceiptForTesting(
        at url: URL,
        expectedSHA256: String,
        afterOpen: @escaping () throws -> Void
    ) throws -> R12NativeRouteObservationV2 {
        try loadCanonicalReceipt(
            at: url,
            expectedSHA256: expectedSHA256,
            afterOpen: afterOpen
        )
    }
    #endif

    private static func loadCanonicalReceipt(
        at url: URL,
        expectedSHA256: String,
        afterOpen: (() throws -> Void)?
    ) throws -> R12NativeRouteObservationV2 {
        let receipt = try openReceiptDescriptor(at: url)
        let descriptor = receipt.descriptor
        defer {
            Darwin.close(descriptor)
        }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_size >= 0,
              opened.st_nlink == 1,
              pathChainMatches(
                  receipt.pathSnapshots,
                  leafDescriptorStatus: opened
              ) else {
            throw R12RouteResolverErrorV2.unsafeNativeReceiptFile(url.path)
        }
        guard opened.st_size <= maximumReceiptSize else {
            throw R12RouteResolverErrorV2.nativeReceiptTooLarge(
                maximumSize: maximumReceiptSize
            )
        }
        try afterOpen?()
        let bytes = try boundedRead(
            descriptor: descriptor,
            path: url.path,
            initialSize: Int(opened.st_size)
        )
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              Self.sameFile(opened, after),
              after.st_nlink == 1,
              pathChainMatches(
                  receipt.pathSnapshots,
                  leafDescriptorStatus: after
              ),
              bytes.count == Int(after.st_size) else {
            throw R12RouteResolverErrorV2.nativeReceiptFileChanged(url.path)
        }
        return try loadCanonicalReceipt(
            bytes,
            expectedSHA256: expectedSHA256
        )
    }

    private static func openReceiptDescriptor(
        at url: URL
    ) throws -> OpenedReceipt {
        let path = url.path
        let components = url.pathComponents
        guard url.isFileURL,
              components.first == "/",
              components.count > 1,
              components.dropFirst().allSatisfy({
                  $0 != "."
                      && $0 != ".."
                      && !$0.isEmpty
                      && !$0.contains("/")
                      && !$0.utf8.contains(0)
              }) else {
            throw R12RouteResolverErrorV2.unsafeNativeReceiptFile(path)
        }
        let snapshots = try pathSnapshots(
            path: path,
            components: components
        )
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw R12RouteResolverErrorV2.unsafeNativeReceiptFile(path)
        }
        var opened = stat()
        let statusResult = fstat(descriptor, &opened)
        let kernelPath = descriptorPath(descriptor)
        let chainMatches = pathChainMatches(
            snapshots,
            leafDescriptorStatus: opened
        )
        guard statusResult == 0,
              opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_nlink == 1,
              kernelPath == path,
              chainMatches else {
            Darwin.close(descriptor)
            throw R12RouteResolverErrorV2.unsafeNativeReceiptFile(path)
        }
        return OpenedReceipt(
            descriptor: descriptor,
            pathSnapshots: snapshots
        )
    }

    private static func pathSnapshots(
        path: String,
        components: [String]
    ) throws -> [ReceiptPathSnapshot] {
        var paths = ["/"]
        var current = ""
        for component in components.dropFirst() {
            current += "/\(component)"
            paths.append(current)
        }
        guard paths.last == path else {
            throw R12RouteResolverErrorV2.unsafeNativeReceiptFile(path)
        }
        return try paths.enumerated().map { offset, componentPath in
            var status = stat()
            guard lstat(componentPath, &status) == 0 else {
                throw R12RouteResolverErrorV2.unsafeNativeReceiptFile(path)
            }
            let type = status.st_mode & mode_t(S_IFMT)
            let isLeaf = offset == paths.count - 1
            guard isLeaf ? type == mode_t(S_IFREG) : type == mode_t(S_IFDIR),
                  !isLeaf || status.st_nlink == 1 else {
                throw R12RouteResolverErrorV2.unsafeNativeReceiptFile(path)
            }
            return ReceiptPathSnapshot(path: componentPath, status: status)
        }
    }

    private static func descriptorPath(_ descriptor: Int32) -> String? {
        var buffer = [CChar](
            repeating: 0,
            count: Int(MAXPATHLEN)
        )
        let result: Int32 = buffer.withUnsafeMutableBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else {
                return Int32(-1)
            }
            return r12FcntlPointer(
                descriptor,
                F_GETPATH,
                UnsafeMutableRawPointer(baseAddress)
            )
        }
        guard result == 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    private static func pathChainMatches(
        _ snapshots: [ReceiptPathSnapshot],
        leafDescriptorStatus: stat
    ) -> Bool {
        guard let leaf = snapshots.last,
              leaf.matches(leafDescriptorStatus),
              leafDescriptorStatus.st_nlink == 1 else {
            return false
        }
        for snapshot in snapshots {
            var current = stat()
            guard lstat(snapshot.path, &current) == 0,
                  snapshot.matches(current) else {
                return false
            }
        }
        return true
    }

    private static func boundedRead(
        descriptor: Int32,
        path: String,
        initialSize: Int
    ) throws -> Data {
        let detectionLimit = maximumReceiptSize + 1
        var data = Data()
        data.reserveCapacity(min(initialSize, maximumReceiptSize))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count < detectionLimit {
            let requested = min(buffer.count, detectionLimit - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw R12RouteResolverErrorV2.nativeReceiptReadFailed(path)
            }
            guard count > 0 else {
                break
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumReceiptSize else {
            throw R12RouteResolverErrorV2.nativeReceiptTooLarge(
                maximumSize: maximumReceiptSize
            )
        }
        return data
    }

    private init(
        document: R12NativeRouteReceiptDocumentV2,
        receiptSHA256: String
    ) throws {
        self.receiptID = try R12RouteResolverValidationV2.identity(
            document.receiptID,
            field: "receipt_id"
        )
        self.receiptSHA256 = receiptSHA256
        self.hostIdentity = try R12HostIdentityV2(
            hostID: document.hostID,
            modelIdentifier: document.modelIdentifier,
            chipIdentity: document.chipIdentity
        )
        self.hardwareProfileID = try R12RouteResolverValidationV2.identity(
            document.hardwareProfileID,
            field: "observation_hardware_profile_id"
        )
        self.hardwareTierIdentity = try R12HardwareTierIdentityV2(
            document.hardwareTierID
        )
        self.routeID = try R12RouteResolverValidationV2.identity(
            document.routeID,
            field: "observation_route_id"
        )
        self.backendID = try R12RouteResolverValidationV2.identity(
            document.backendID,
            field: "observation_backend_id"
        )
        self.scaleFactor = try R12ExactScaleFactorV2(
            numerator: document.scaleNumerator,
            denominator: document.scaleDenominator
        )
        self.inputContractSHA256 = try R12RouteResolverValidationV2.sha256(
            document.inputContractSHA256,
            field: "observation_input_contract_sha256"
        )
        self.outputContractSHA256 = try R12RouteResolverValidationV2.sha256(
            document.outputContractSHA256,
            field: "observation_output_contract_sha256"
        )
        self.authority = .integrityVerifiedObservationNotObserved
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
    }
}

private struct R12NativeRouteReceiptDocumentV2: Codable {
    let artifactKind: String
    let schemaVersion: String
    let receiptID: String
    let hostID: String
    let modelIdentifier: String
    let chipIdentity: String
    let hardwareProfileID: String
    let hardwareTierID: String
    let routeID: String
    let backendID: String
    let scaleNumerator: Int64
    let scaleDenominator: Int64
    let inputContractSHA256: String
    let outputContractSHA256: String

    enum CodingKeys: String, CodingKey {
        case artifactKind = "artifact_kind"
        case schemaVersion = "schema_version"
        case receiptID = "receipt_id"
        case hostID = "host_id"
        case modelIdentifier = "model_identifier"
        case chipIdentity = "chip_identity"
        case hardwareProfileID = "hardware_profile_id"
        case hardwareTierID = "hardware_tier_id"
        case routeID = "route_id"
        case backendID = "backend_id"
        case scaleNumerator = "scale_numerator"
        case scaleDenominator = "scale_denominator"
        case inputContractSHA256 = "input_contract_sha256"
        case outputContractSHA256 = "output_contract_sha256"
    }
}

enum R12RouteAttemptDispositionV2: String, Hashable, Sendable {
    case rejected
    case selected
}

enum R12RouteRejectionReasonV2: String, Hashable, Sendable {
    case hardwareProfileDoesNotDeclareRoute = "hardware_profile_does_not_declare_route"
    case formatTransitionUnsupported = "format_transition_unsupported"
    case sourceResolutionUnsupported = "source_resolution_unsupported"
    case targetResolutionUnsupported = "target_resolution_unsupported"
    case exactScaleUnsupported = "exact_scale_unsupported"
    case fixtureCannotAuthorizeNative = "fixture_cannot_authorize_native"
    case nativeObservationMissing = "native_observation_missing"
    case nativeObservationMismatch = "native_observation_mismatch"
    case nativeObservationNotObserved = "native_observation_not_observed"
}

struct R12RouteFallbackRecordV2: Hashable, Sendable {
    let attemptOrdinal: Int
    let routeID: String
    let backendID: String
    let disposition: R12RouteAttemptDispositionV2
    let rejectionReason: R12RouteRejectionReasonV2?
}

enum R12RouteSelectionEvidenceV2: Hashable, Sendable {
    case deterministicContract
    case nativeObserved(R12NativeRouteObservationV2)
}

struct R12ResolvedRouteV2: Hashable, Sendable {
    let routeID: String
    let backendID: String
    let scaleFactor: R12ExactScaleFactorV2
    let inputContractSHA256: String
    let outputContractSHA256: String
    let hardwareProfileID: String
    let hardwareTierIdentity: R12HardwareTierIdentityV2
    let evidence: R12RouteSelectionEvidenceV2
    let authority = R12RouteSelectionAuthorityV2.softwareFunctionOnly
}

struct R12RouteResolutionV2: Hashable, Sendable {
    let selectedRoute: R12ResolvedRouteV2?
    let fallbackRecords: [R12RouteFallbackRecordV2]
    let authority = R12RouteSelectionAuthorityV2.softwareFunctionOnly

    var isAvailable: Bool {
        selectedRoute != nil
    }
}

enum R12RouteAndHardwareResolverV2 {
    static func resolve(
        request: R12RouteRequestV2,
        candidates: [R12RouteCapabilityV2],
        nativeObservations: [R12NativeRouteObservationV2] = []
    ) throws -> R12RouteResolutionV2 {
        let candidateIndex = try validateCandidates(candidates)
        let observationIndex = try validateObservations(
            nativeObservations,
            candidates: candidateIndex
        )
        let orderedCandidates = candidates.sorted {
            if $0.preferenceOrdinal != $1.preferenceOrdinal {
                return $0.preferenceOrdinal < $1.preferenceOrdinal
            }
            if $0.routeID != $1.routeID {
                return $0.routeID < $1.routeID
            }
            return $0.backendCapability.backendID < $1.backendCapability.backendID
        }

        var records: [R12RouteFallbackRecordV2] = []
        for candidate in orderedCandidates {
            if let rejection = rejectionReason(
                candidate: candidate,
                request: request,
                observation: observationIndex[candidate.routeID]
            ) {
                records.append(
                    record(
                        candidate: candidate,
                        ordinal: records.count,
                        rejection: rejection
                    )
                )
                continue
            }

            let evidence: R12RouteSelectionEvidenceV2
            switch candidate.executionRequirement {
            case .deterministicContract:
                evidence = .deterministicContract
            case .nativeObserved:
                guard let observation = observationIndex[candidate.routeID] else {
                    preconditionFailure("Native observation was validated before selection")
                }
                evidence = .nativeObserved(observation)
            }
            let selected = R12ResolvedRouteV2(
                routeID: candidate.routeID,
                backendID: candidate.backendCapability.backendID,
                scaleFactor: request.scaleFactor,
                inputContractSHA256: request.inputFormat.canonicalSHA256,
                outputContractSHA256: request.outputFormat.canonicalSHA256,
                hardwareProfileID: request.hardwareProfile.profileID,
                hardwareTierIdentity: request.hardwareProfile.tierIdentity,
                evidence: evidence
            )
            records.append(
                R12RouteFallbackRecordV2(
                    attemptOrdinal: records.count,
                    routeID: candidate.routeID,
                    backendID: candidate.backendCapability.backendID,
                    disposition: .selected,
                    rejectionReason: nil
                )
            )
            return R12RouteResolutionV2(
                selectedRoute: selected,
                fallbackRecords: records
            )
        }
        return R12RouteResolutionV2(
            selectedRoute: nil,
            fallbackRecords: records
        )
    }

    private static func rejectionReason(
        candidate: R12RouteCapabilityV2,
        request: R12RouteRequestV2,
        observation: R12NativeRouteObservationV2?
    ) -> R12RouteRejectionReasonV2? {
        guard request.hardwareProfile.declaresAvailable(routeID: candidate.routeID) else {
            return .hardwareProfileDoesNotDeclareRoute
        }
        guard candidate.formatTransitions.contains(where: {
            $0.matches(input: request.inputFormat, output: request.outputFormat)
        }) else {
            return .formatTransitionUnsupported
        }
        guard candidate.sourceResolutionBounds.supports(
            request.sourceResolution
        ) else {
            return .sourceResolutionUnsupported
        }
        guard candidate.targetResolutionBounds.supports(
            request.targetResolution
        ) else {
            return .targetResolutionUnsupported
        }
        guard candidate.supportedScaleFactors.contains(request.scaleFactor) else {
            return .exactScaleUnsupported
        }
        guard candidate.executionRequirement == .nativeObserved else {
            return nil
        }
        guard case .nativeHost(let expectedHost) =
            request.hardwareProfile.executionContext else {
            return .fixtureCannotAuthorizeNative
        }
        guard let observation else {
            return .nativeObservationMissing
        }
        guard observation.hostIdentity == expectedHost,
              observation.hardwareProfileID == request.hardwareProfile.profileID,
              observation.hardwareTierIdentity == request.hardwareProfile.tierIdentity,
              observation.routeID == candidate.routeID,
              observation.backendID == candidate.backendCapability.backendID,
              observation.scaleFactor == request.scaleFactor,
              observation.inputContractSHA256 == request.inputFormat.canonicalSHA256,
              observation.outputContractSHA256 == request.outputFormat.canonicalSHA256 else {
            return .nativeObservationMismatch
        }
        guard observation.authority == .trustedExternalObservation else {
            return .nativeObservationNotObserved
        }
        return nil
    }

    private static func record(
        candidate: R12RouteCapabilityV2,
        ordinal: Int,
        rejection: R12RouteRejectionReasonV2
    ) -> R12RouteFallbackRecordV2 {
        R12RouteFallbackRecordV2(
            attemptOrdinal: ordinal,
            routeID: candidate.routeID,
            backendID: candidate.backendCapability.backendID,
            disposition: .rejected,
            rejectionReason: rejection
        )
    }

    private static func validateCandidates(
        _ candidates: [R12RouteCapabilityV2]
    ) throws -> [String: R12RouteCapabilityV2] {
        var index: [String: R12RouteCapabilityV2] = [:]
        for candidate in candidates {
            guard index.updateValue(candidate, forKey: candidate.routeID) == nil else {
                throw R12RouteResolverErrorV2.duplicateCandidateRoute(
                    candidate.routeID
                )
            }
        }
        return index
    }

    private static func validateObservations(
        _ observations: [R12NativeRouteObservationV2],
        candidates: [String: R12RouteCapabilityV2]
    ) throws -> [String: R12NativeRouteObservationV2] {
        var index: [String: R12NativeRouteObservationV2] = [:]
        for observation in observations {
            guard let candidate = candidates[observation.routeID] else {
                throw R12RouteResolverErrorV2.nativeObservationForUnknownRoute(
                    observation.routeID
                )
            }
            guard candidate.executionRequirement == .nativeObserved else {
                throw R12RouteResolverErrorV2
                    .nativeObservationForDeterministicRoute(observation.routeID)
            }
            guard index.updateValue(observation, forKey: observation.routeID) == nil else {
                throw R12RouteResolverErrorV2.duplicateNativeObservation(
                    observation.routeID
                )
            }
        }
        return index
    }
}

private enum R12RouteResolverValidationV2 {
    static func identity(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value else {
            throw R12RouteResolverErrorV2.invalidIdentity(field: field)
        }
        return value
    }

    static func sha256(_ value: String, field: String) throws -> String {
        guard value.utf8.count == 64,
              Set(value).count > 1,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(Int(byte)) || (97...102).contains(Int(byte))
              }) else {
            throw R12RouteResolverErrorV2.invalidSHA256(field: field)
        }
        return value
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
