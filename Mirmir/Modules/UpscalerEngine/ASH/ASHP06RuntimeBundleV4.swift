import Foundation

enum ASHP06RuntimeBundleV4Error: Error, Equatable, Sendable {
    case outputAlreadyExists(String)
    case outputParentMissing(String)
    case invalidBuildInput(String)
    case incompleteBuildInput(missing: [ASHRuntimeArtifactRoleV4])
    case duplicateBuildInput(ASHRuntimeArtifactRoleV4)
    case artifactNotCanonicalJSON(ASHRuntimeArtifactRoleV4)
    case artifactEnvelopeMismatch(ASHRuntimeArtifactRoleV4)
    case forbiddenPreviewArtifact(ASHRuntimeArtifactRoleV4)
    case invalidMetalLibrary
    case metalLibraryValidationFailed(String)
    case bundleNotDirectory(String)
    case symbolicLink(String)
    case manifestTooLarge(Int)
    case manifestIdentityMismatch(expected: ASHSHA256V4, actual: ASHSHA256V4)
    case untrustedSourceRevision(String)
    case untrustedBuilder(ASHSHA256V4)
    case unexpectedBundleEntry(String)
    case missingBundleEntry(String)
    case artifactSizeMismatch(
        role: ASHRuntimeArtifactRoleV4,
        expected: Int64,
        actual: Int64
    )
    case artifactTooLarge(role: ASHRuntimeArtifactRoleV4, byteCount: Int64)
    case bundleTooLarge(Int64)
    case artifactHashMismatch(
        role: ASHRuntimeArtifactRoleV4,
        expected: ASHSHA256V4,
        actual: ASHSHA256V4
    )
    case codewordTableMismatch
    case coreCertificateMismatch
    case measurementContractMismatch
    case branchAggregationMismatch
    case operatorBankMismatch
    case branchOperatorBindingMismatch
    case metalCompilerBindingMismatch
    case verifiedBindingInvalid
}

protocol ASHMetalLibraryValidatingV4: Sendable {
    /// Must compile/load the exact bytes as an executable Metal library. A
    /// file-signature or extension check alone does not satisfy this contract.
    func validateExecutableMetalLibrary(_ data: Data) throws
}

struct ASHP06RuntimeArtifactInputV4: Equatable, Sendable {
    let role: ASHRuntimeArtifactRoleV4
    let data: Data
}

struct ASHP06RuntimeBuildProvenanceV4: Equatable, Sendable {
    let sourceRevision: String
    let builderID: String
    let builderSourceSHA256: ASHSHA256V4
    let buildParametersSHA256: ASHSHA256V4
    let toolchain: ASHRuntimeToolchainV4
}

struct ASHP06RuntimeBuildRequestV4: Equatable, Sendable {
    let releaseStatus: ASHRuntimeReleaseStatusV4
    let provenance: ASHP06RuntimeBuildProvenanceV4
    let artifacts: [ASHP06RuntimeArtifactInputV4]
}

struct ASHP06RuntimeBuildResultV4: Equatable, Sendable {
    let bundleURL: URL
    let manifest: ASHRuntimeManifestV4
    let manifestSHA256: ASHSHA256V4
}

struct ASHRuntimeTrustPolicyV4: Equatable, Sendable {
    let expectedManifestSHA256: ASHSHA256V4
    let requiredReleaseStatus: ASHRuntimeReleaseStatusV4
    let allowedSourceRevisions: Set<String>
    let allowedBuilderSourceSHA256: Set<ASHSHA256V4>
    let maximumArtifactByteCount: Int64
    let maximumBundleByteCount: Int64

    init(
        expectedManifestSHA256: ASHSHA256V4,
        requiredReleaseStatus: ASHRuntimeReleaseStatusV4 = .releaseQualified,
        allowedSourceRevisions: Set<String>,
        allowedBuilderSourceSHA256: Set<ASHSHA256V4>,
        maximumArtifactByteCount: Int64 = 256 * 1_024 * 1_024,
        maximumBundleByteCount: Int64 = 512 * 1_024 * 1_024
    ) throws {
        guard !allowedSourceRevisions.isEmpty,
              !allowedBuilderSourceSHA256.isEmpty,
              maximumArtifactByteCount > 0,
              maximumBundleByteCount >= maximumArtifactByteCount else {
            throw ASHP06RuntimeBundleV4Error.invalidBuildInput(
                "invalid trust-policy bounds or empty trust roots"
            )
        }
        self.expectedManifestSHA256 = expectedManifestSHA256
        self.requiredReleaseStatus = requiredReleaseStatus
        self.allowedSourceRevisions = allowedSourceRevisions
        self.allowedBuilderSourceSHA256 = allowedBuilderSourceSHA256
        self.maximumArtifactByteCount = maximumArtifactByteCount
        self.maximumBundleByteCount = maximumBundleByteCount
    }
}

/// Immutable bytes returned only after the bundle directory, manifest trust
/// root, every artifact hash, schema, provenance binding, and completeness set
/// have been checked. Holding the bytes closes the load-to-use replacement
/// window for executors.
struct ASHVerifiedRuntimeBundleV4: @unchecked Sendable {
    let bundleURL: URL
    let manifest: ASHRuntimeManifestV4
    let manifestSHA256: ASHSHA256V4
    private let artifactsByRole: [ASHRuntimeArtifactRoleV4: Data]

    fileprivate init(
        bundleURL: URL,
        manifest: ASHRuntimeManifestV4,
        manifestSHA256: ASHSHA256V4,
        artifactsByRole: [ASHRuntimeArtifactRoleV4: Data]
    ) {
        self.bundleURL = bundleURL
        self.manifest = manifest
        self.manifestSHA256 = manifestSHA256
        self.artifactsByRole = artifactsByRole
    }

    func artifactData(for role: ASHRuntimeArtifactRoleV4) -> Data {
        // Loader completeness makes this total.
        artifactsByRole[role]!
    }

    func measurementContract() throws -> ASHMeasurementContractV4 {
        let artifact = try ASHCanonicalJSONV4.decode(
            ASHP06MeasurementContractArtifactV4.self,
            from: artifactData(for: .measurementContract)
        )
        return try artifact.validatedContract()
    }

    func branchProgram() throws -> ASHDepthFourBranchProgramV4 {
        let artifact = try ASHCanonicalJSONV4.decode(
            ASHP06BranchAggregationArtifactV4.self,
            from: artifactData(for: .branchAggregation)
        )
        return try artifact.validatedProgram()
    }

    func verifyBinding() throws {
        try manifest.validate()
        guard try manifest.canonicalSHA256 == manifestSHA256,
              artifactsByRole.count == ASHRuntimeArtifactRoleV4.allCases.count
        else {
            throw ASHP06RuntimeBundleV4Error.verifiedBindingInvalid
        }
        for descriptor in manifest.artifacts {
            guard let bytes = artifactsByRole[descriptor.role],
                  Int64(bytes.count) == descriptor.byteCount,
                  ASHSHA256V4(rawData: bytes) == descriptor.contentSHA256 else {
                throw ASHP06RuntimeBundleV4Error.verifiedBindingInvalid
            }
        }
    }
}

struct ASHP06CodewordTablesArtifactV4: Codable, Equatable, Sendable {
    let schemaID: String
    let artifactRole: String
    let generatorRows: [UInt16]
    let codewordsByMessage: [UInt16]
    let codewordsByNumericCodeword: [UInt16]
    let messageByNumericCodeword: [UInt8]
    let translationInvariantCoordinate: Int
    let integrityCoordinate: Int

    static func canonical() -> Self {
        let codewordsByMessage = ASHCoreV4.canonicalCodewordsByMessage
            .map(\.rawValue)
        let sortedPairs = codewordsByMessage.enumerated().sorted {
            $0.element < $1.element
        }
        return Self(
            schemaID: ASHRuntimeArtifactRoleV4.codewordTables.expectedSchemaID,
            artifactRole: ASHRuntimeArtifactRoleV4.codewordTables.rawValue,
            generatorRows: ASHCoreV4.canonicalGeneratorRows.map(\.rawValue),
            codewordsByMessage: codewordsByMessage,
            codewordsByNumericCodeword: sortedPairs.map(\.element),
            messageByNumericCodeword: sortedPairs.map { UInt8($0.offset) },
            translationInvariantCoordinate:
                ASHCoreV4.translationInvariantCoordinate,
            integrityCoordinate: ASHCoreV4.integrityCoordinate
        )
    }

    func validate() throws {
        guard self == Self.canonical() else {
            throw ASHP06RuntimeBundleV4Error.codewordTableMismatch
        }
    }
}

struct ASHP06CoreCertificateArtifactV4: Codable, Equatable, Sendable {
    let schemaID: String
    let artifactRole: String
    let stateCount: Int
    let integrityStateCount: Int
    let codewordCount: Int
    let minimumCodeDistance: Int
    let strictExactCount: Int
    let strictCorrectedCount: Int
    let strictRejectedCount: Int
    let affineExactCount: Int
    let affineOneBitCorrectedCount: Int
    let affineTwoBitRejectedCount: Int
    let orbitCount: Int
    let integrityOrbitCount: Int
    let branchLeafCount: UInt64
    let branchMassDenominator: UInt64
    let branchMassNumeratorsByMessage: [UInt64]
    let codewordTablesSHA256: ASHSHA256V4

    static func canonical(codewordTablesSHA256: ASHSHA256V4) -> Self {
        Self(
            schemaID: ASHRuntimeArtifactRoleV4.coreCertificate.expectedSchemaID,
            artifactRole: ASHRuntimeArtifactRoleV4.coreCertificate.rawValue,
            stateCount: 512,
            integrityStateCount: 256,
            codewordCount: 16,
            minimumCodeDistance: 4,
            strictExactCount: 16,
            strictCorrectedCount: 144,
            strictRejectedCount: 352,
            affineExactCount: 4_096,
            affineOneBitCorrectedCount: 36_864,
            affineTwoBitRejectedCount: 147_456,
            orbitCount: 32,
            integrityOrbitCount: 16,
            branchLeafCount: 81,
            branchMassDenominator: 256,
            branchMassNumeratorsByMessage:
                ASHCoreV4.expectedDepthFourBranchMassNumerators,
            codewordTablesSHA256: codewordTablesSHA256
        )
    }

    func validate(codewordTablesSHA256: ASHSHA256V4) throws {
        guard self == Self.canonical(
            codewordTablesSHA256: codewordTablesSHA256
        ) else {
            throw ASHP06RuntimeBundleV4Error.coreCertificateMismatch
        }
    }
}

struct ASHP06MeasurementContractArtifactV4: Codable, Equatable, Sendable {
    let schemaID: String
    let artifactRole: String
    let contractID: String
    let canonicalBinarySHA256: ASHSHA256V4
    let canonicalBinaryHex: String

    static func canonical() throws -> Self {
        let bytes = try ASHMeasurementContractV4.canonicalP06
            .serializedCanonical()
        return Self(
            schemaID: ASHRuntimeArtifactRoleV4.measurementContract
                .expectedSchemaID,
            artifactRole: ASHRuntimeArtifactRoleV4.measurementContract.rawValue,
            contractID: ASHMeasurementContractV4.canonicalContractID,
            canonicalBinarySHA256: ASHSHA256V4(rawData: bytes),
            canonicalBinaryHex: ASHP06ArtifactHexV4.encode(bytes)
        )
    }

    func validatedContract() throws -> ASHMeasurementContractV4 {
        guard schemaID
                == ASHRuntimeArtifactRoleV4.measurementContract.expectedSchemaID,
              artifactRole
                == ASHRuntimeArtifactRoleV4.measurementContract.rawValue,
              contractID == ASHMeasurementContractV4.canonicalContractID,
              let bytes = ASHP06ArtifactHexV4.decode(canonicalBinaryHex),
              ASHSHA256V4(rawData: bytes) == canonicalBinarySHA256,
              let contract = try? ASHMeasurementContractV4.decodeCanonical(
                  from: bytes
              ),
              contract == .canonicalP06 else {
            throw ASHP06RuntimeBundleV4Error.measurementContractMismatch
        }
        return contract
    }

    func validate() throws {
        _ = try validatedContract()
    }
}

struct ASHP06BranchAggregationArtifactV4: Codable, Equatable, Sendable {
    let schemaID: String
    let artifactRole: String
    let programID: String
    let operatorManifestID: String
    let canonicalBinarySHA256: ASHSHA256V4
    let canonicalBinaryHex: String

    static func canonical() throws -> Self {
        let program = try ASHDepthFourBranchCompilerV4.compileCanonical()
        let bytes = try program.serializedCanonical()
        return Self(
            schemaID: ASHRuntimeArtifactRoleV4.branchAggregation
                .expectedSchemaID,
            artifactRole: ASHRuntimeArtifactRoleV4.branchAggregation.rawValue,
            programID: program.programID,
            operatorManifestID: program.operatorManifest.manifestID,
            canonicalBinarySHA256: ASHSHA256V4(rawData: bytes),
            canonicalBinaryHex: ASHP06ArtifactHexV4.encode(bytes)
        )
    }

    func validatedProgram() throws -> ASHDepthFourBranchProgramV4 {
        guard schemaID
                == ASHRuntimeArtifactRoleV4.branchAggregation.expectedSchemaID,
              artifactRole == ASHRuntimeArtifactRoleV4.branchAggregation.rawValue,
              programID == ASHDepthFourBranchProgramV4.canonicalProgramID,
              operatorManifestID
                == ASHOperatorManifestV4.canonicalP06.manifestID,
              let bytes = ASHP06ArtifactHexV4.decode(canonicalBinaryHex),
              ASHSHA256V4(rawData: bytes) == canonicalBinarySHA256,
              let program = try? ASHDepthFourBranchProgramV4.decodeCanonical(
                  from: bytes
              ) else {
            throw ASHP06RuntimeBundleV4Error.branchAggregationMismatch
        }
        do {
            try program.validateCanonical()
        } catch {
            throw ASHP06RuntimeBundleV4Error.branchAggregationMismatch
        }
        return program
    }
}

struct ASHP06OperatorBankEntryArtifactV4: Codable, Equatable, Sendable {
    let messageRawValue: UInt8
    let coefficients: [Int16]
}

struct ASHP06OperatorBankArtifactV4: Codable, Equatable, Sendable {
    let schemaID: String
    let artifactRole: String
    let manifestID: String
    let basisIDs: [String]
    let entries: [ASHP06OperatorBankEntryArtifactV4]
    let branchProgramSHA256: ASHSHA256V4

    static func canonical(
        branchProgramSHA256: ASHSHA256V4
    ) -> Self {
        let manifest = ASHOperatorManifestV4.canonicalP06
        return Self(
            schemaID: ASHRuntimeArtifactRoleV4.operatorBank.expectedSchemaID,
            artifactRole: ASHRuntimeArtifactRoleV4.operatorBank.rawValue,
            manifestID: manifest.manifestID,
            basisIDs: manifest.basisIDs,
            entries: manifest.entries.map {
                ASHP06OperatorBankEntryArtifactV4(
                    messageRawValue: $0.messageRawValue,
                    coefficients: $0.coefficients
                )
            },
            branchProgramSHA256: branchProgramSHA256
        )
    }

    func validate(
        program: ASHDepthFourBranchProgramV4,
        branchProgramSHA256: ASHSHA256V4
    ) throws {
        let canonical = Self.canonical(
            branchProgramSHA256: branchProgramSHA256
        )
        guard self == canonical,
              manifestID == program.operatorManifest.manifestID,
              basisIDs == program.operatorManifest.basisIDs,
              entries.map(\.messageRawValue)
                == program.operatorManifest.entries.map(\.messageRawValue),
              entries.map(\.coefficients)
                == program.operatorManifest.entries.map(\.coefficients) else {
            throw ASHP06RuntimeBundleV4Error.operatorBankMismatch
        }
    }
}

struct ASHP06MetalCompilerContractArtifactV4: Codable, Equatable, Sendable {
    let schemaID: String
    let artifactRole: String
    let metalLibrarySHA256: ASHSHA256V4
    let compilerIdentity: String
    let languageVersion: String
    let sdkBuildIdentity: String
    let targetTriple: String

    func validate(
        provenance: ASHRuntimeProvenanceV4
    ) throws {
        guard schemaID
                == ASHRuntimeArtifactRoleV4.metalCompilerContract.expectedSchemaID,
              artifactRole == ASHRuntimeArtifactRoleV4.metalCompilerContract.rawValue,
              metalLibrarySHA256 == provenance.metalLibrarySHA256,
              compilerIdentity == provenance.toolchain.metalCompilerIdentity,
              languageVersion == provenance.toolchain.metalLanguageVersion,
              sdkBuildIdentity == provenance.toolchain.sdkBuildIdentity,
              targetTriple == provenance.toolchain.targetTriple else {
            throw ASHP06RuntimeBundleV4Error.metalCompilerBindingMismatch
        }
    }
}

enum ASHP06RuntimeBundleBuilderV4 {
    static func build(
        _ request: ASHP06RuntimeBuildRequestV4,
        at outputURL: URL,
        metalLibraryValidator: any ASHMetalLibraryValidatingV4,
        fileManager: FileManager = .default
    ) throws -> ASHP06RuntimeBuildResultV4 {
        let output = outputURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard !fileManager.fileExists(
            atPath: output.path,
            isDirectory: &isDirectory
        ) else {
            throw ASHP06RuntimeBundleV4Error.outputAlreadyExists(output.path)
        }
        let parent = output.deletingLastPathComponent()
        guard fileManager.fileExists(
            atPath: parent.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ASHP06RuntimeBundleV4Error.outputParentMissing(parent.path)
        }

        let inputs = try validatedInputs(request)
        let descriptors = inputs.map { input in
            ASHRuntimeArtifactV4(
                role: input.role,
                relativePath: input.role.canonicalRelativePath,
                schemaID: input.role.expectedSchemaID,
                contentSHA256: ASHSHA256V4(rawData: input.data),
                byteCount: Int64(input.data.count)
            )
        }.sorted { $0.role < $1.role }
        let inputSetIdentity = try ASHCanonicalJSONV4.hash(
            descriptors,
            domain: "ash-p06-runtime-input-set-v4"
        )
        let metalHash = descriptors.first(where: { $0.role == .metalLibrary })!
            .contentSHA256
        let provenance = ASHRuntimeProvenanceV4(
            sourceRevision: request.provenance.sourceRevision,
            builderID: request.provenance.builderID,
            builderSourceSHA256: request.provenance.builderSourceSHA256,
            buildParametersSHA256: request.provenance.buildParametersSHA256,
            inputSetSHA256: inputSetIdentity,
            metalLibrarySHA256: metalHash,
            toolchain: request.provenance.toolchain
        )
        let manifest = try ASHRuntimeManifestV4(
            releaseStatus: request.releaseStatus,
            provenance: provenance,
            artifacts: descriptors
        )
        try validateCrossBindings(inputs: inputs, manifest: manifest)
        let manifestData = try ASHCanonicalJSONV4.encode(manifest)
        let manifestSHA256 = try manifest.canonicalSHA256

        let staging = parent.appendingPathComponent(
            ".\(output.lastPathComponent).p06-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: staging)
            }
        }
        try fileManager.createDirectory(
            at: staging.appendingPathComponent("artifacts", isDirectory: true),
            withIntermediateDirectories: true
        )
        for input in inputs {
            try input.data.write(
                to: staging.appendingPathComponent(
                    input.role.canonicalRelativePath,
                    isDirectory: false
                ),
                options: .atomic
            )
        }
        try manifestData.write(
            to: staging.appendingPathComponent(ASHRuntimeManifestV4.fileName),
            options: .atomic
        )
        try fileManager.moveItem(at: staging, to: output)
        shouldRemoveStaging = false

        let policy = try ASHRuntimeTrustPolicyV4(
            expectedManifestSHA256: manifestSHA256,
            requiredReleaseStatus: request.releaseStatus,
            allowedSourceRevisions: [provenance.sourceRevision],
            allowedBuilderSourceSHA256: [provenance.builderSourceSHA256]
        )
        _ = try ASHP06RuntimeBundleLoaderV4.load(
            at: output,
            trustPolicy: policy,
            metalLibraryValidator: metalLibraryValidator,
            fileManager: fileManager
        )
        return ASHP06RuntimeBuildResultV4(
            bundleURL: output,
            manifest: manifest,
            manifestSHA256: manifestSHA256
        )
    }

    static func canonicalArtifactData<T: Encodable>(
        role: ASHRuntimeArtifactRoleV4,
        document: T
    ) throws -> ASHP06RuntimeArtifactInputV4 {
        let data = try ASHCanonicalJSONV4.encode(document)
        try validateArtifactData(
            data,
            role: role,
            releaseStatus: .semanticCandidate
        )
        return ASHP06RuntimeArtifactInputV4(role: role, data: data)
    }

    private static func validatedInputs(
        _ request: ASHP06RuntimeBuildRequestV4
    ) throws -> [ASHP06RuntimeArtifactInputV4] {
        var byRole: [ASHRuntimeArtifactRoleV4: ASHP06RuntimeArtifactInputV4] = [:]
        for input in request.artifacts {
            guard byRole.updateValue(input, forKey: input.role) == nil else {
                throw ASHP06RuntimeBundleV4Error.duplicateBuildInput(input.role)
            }
            try validateArtifactData(
                input.data,
                role: input.role,
                releaseStatus: request.releaseStatus
            )
        }
        let missing = Set(ASHRuntimeArtifactRoleV4.allCases)
            .subtracting(byRole.keys).sorted()
        guard missing.isEmpty else {
            throw ASHP06RuntimeBundleV4Error.incompleteBuildInput(missing: missing)
        }
        return byRole.values.sorted { $0.role < $1.role }
    }

    fileprivate static func validateArtifactData(
        _ data: Data,
        role: ASHRuntimeArtifactRoleV4,
        releaseStatus: ASHRuntimeReleaseStatusV4
    ) throws {
        guard !data.isEmpty else {
            throw ASHP06RuntimeBundleV4Error.invalidBuildInput(
                "empty \(role.rawValue) artifact"
            )
        }
        if role == .metalLibrary {
            guard data.count >= 4,
                  Array(data.prefix(4)) == Array("MTLB".utf8) else {
                throw ASHP06RuntimeBundleV4Error.invalidMetalLibrary
            }
            return
        }
        let parsed: ASHCanonicalJSONValueV4
        do {
            parsed = try ASHCanonicalJSONV4.parse(data)
        } catch {
            throw ASHP06RuntimeBundleV4Error.artifactNotCanonicalJSON(role)
        }
        guard ASHCanonicalJSONV4.encode(parsed) == data,
              case .object(let object) = parsed,
              object["schemaID"] == .string(role.expectedSchemaID),
              object["artifactRole"] == .string(role.rawValue) else {
            throw ASHP06RuntimeBundleV4Error.artifactEnvelopeMismatch(role)
        }
        if releaseStatus == .releaseQualified,
           let text = String(data: data, encoding: .utf8)?.lowercased(),
           text.contains("p05")
            || text.contains("preview")
            || text.contains("development") {
            throw ASHP06RuntimeBundleV4Error.forbiddenPreviewArtifact(role)
        }
    }

    fileprivate static func validateCrossBindings(
        inputs: [ASHP06RuntimeArtifactInputV4],
        manifest: ASHRuntimeManifestV4
    ) throws {
        let byRole = Dictionary(uniqueKeysWithValues: inputs.map { ($0.role, $0.data) })
        let codewordData = byRole[.codewordTables]!
        let codewords = try ASHCanonicalJSONV4.decode(
            ASHP06CodewordTablesArtifactV4.self,
            from: codewordData
        )
        try codewords.validate()
        let certificate = try ASHCanonicalJSONV4.decode(
            ASHP06CoreCertificateArtifactV4.self,
            from: byRole[.coreCertificate]!
        )
        try certificate.validate(
            codewordTablesSHA256: ASHSHA256V4(rawData: codewordData)
        )
        let measurement = try ASHCanonicalJSONV4.decode(
            ASHP06MeasurementContractArtifactV4.self,
            from: byRole[.measurementContract]!
        )
        try measurement.validate()
        let branch = try ASHCanonicalJSONV4.decode(
            ASHP06BranchAggregationArtifactV4.self,
            from: byRole[.branchAggregation]!
        )
        let program = try branch.validatedProgram()
        let operatorBank = try ASHCanonicalJSONV4.decode(
            ASHP06OperatorBankArtifactV4.self,
            from: byRole[.operatorBank]!
        )
        try operatorBank.validate(
            program: program,
            branchProgramSHA256: branch.canonicalBinarySHA256
        )
        let metalContract = try ASHCanonicalJSONV4.decode(
            ASHP06MetalCompilerContractArtifactV4.self,
            from: byRole[.metalCompilerContract]!
        )
        try metalContract.validate(provenance: manifest.provenance)
    }
}

private enum ASHP06ArtifactHexV4 {
    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else {
            return nil
        }
        var result = Data()
        result.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]),
                  let low = nibble(bytes[index + 1]) else {
                return nil
            }
            result.append((high << 4) | low)
            index += 2
        }
        guard encode(result) == value else { return nil }
        return result
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}

enum ASHP06RuntimeBundleLoaderV4 {
    static func load(
        at bundleURL: URL,
        trustPolicy: ASHRuntimeTrustPolicyV4,
        metalLibraryValidator: any ASHMetalLibraryValidatingV4,
        fileManager: FileManager = .default
    ) throws -> ASHVerifiedRuntimeBundleV4 {
        let requestedBundle = bundleURL.standardizedFileURL
        let bundleValues = try requestedBundle.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard bundleValues.isDirectory == true else {
            throw ASHP06RuntimeBundleV4Error.bundleNotDirectory(
                requestedBundle.path
            )
        }
        guard bundleValues.isSymbolicLink != true else {
            throw ASHP06RuntimeBundleV4Error.symbolicLink(requestedBundle.path)
        }
        let bundle = requestedBundle

        let manifestURL = bundle.appendingPathComponent(
            ASHRuntimeManifestV4.fileName
        )
        let manifestValues = try manifestURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard manifestValues.isRegularFile == true,
              manifestValues.isSymbolicLink != true else {
            throw ASHP06RuntimeBundleV4Error.missingBundleEntry(
                ASHRuntimeManifestV4.fileName
            )
        }
        let manifestSize = manifestValues.fileSize ?? Int.max
        guard manifestSize <= 2 * 1_024 * 1_024 else {
            throw ASHP06RuntimeBundleV4Error.manifestTooLarge(manifestSize)
        }
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try ASHCanonicalJSONV4.decode(
            ASHRuntimeManifestV4.self,
            from: manifestData
        )
        try manifest.validate(requiring: trustPolicy.requiredReleaseStatus)
        let manifestSHA256 = try manifest.canonicalSHA256
        guard manifestSHA256 == trustPolicy.expectedManifestSHA256 else {
            throw ASHP06RuntimeBundleV4Error.manifestIdentityMismatch(
                expected: trustPolicy.expectedManifestSHA256,
                actual: manifestSHA256
            )
        }
        guard trustPolicy.allowedSourceRevisions.contains(
            manifest.provenance.sourceRevision
        ) else {
            throw ASHP06RuntimeBundleV4Error.untrustedSourceRevision(
                manifest.provenance.sourceRevision
            )
        }
        guard trustPolicy.allowedBuilderSourceSHA256.contains(
            manifest.provenance.builderSourceSHA256
        ) else {
            throw ASHP06RuntimeBundleV4Error.untrustedBuilder(
                manifest.provenance.builderSourceSHA256
            )
        }

        let expectedFiles = Set(
            [ASHRuntimeManifestV4.fileName]
                + manifest.artifacts.map(\.relativePath)
        )
        let observedFiles = try regularFiles(
            in: bundle,
            fileManager: fileManager
        )
        if let unexpected = observedFiles.subtracting(expectedFiles).sorted().first {
            throw ASHP06RuntimeBundleV4Error.unexpectedBundleEntry(unexpected)
        }
        if let missing = expectedFiles.subtracting(observedFiles).sorted().first {
            throw ASHP06RuntimeBundleV4Error.missingBundleEntry(missing)
        }

        var totalByteCount = Int64(manifestData.count)
        var loaded: [ASHRuntimeArtifactRoleV4: Data] = [:]
        for descriptor in manifest.artifacts {
            let url = bundle.appendingPathComponent(descriptor.relativePath)
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true else {
                throw ASHP06RuntimeBundleV4Error.missingBundleEntry(
                    descriptor.relativePath
                )
            }
            guard values.isSymbolicLink != true else {
                throw ASHP06RuntimeBundleV4Error.symbolicLink(
                    descriptor.relativePath
                )
            }
            let size = Int64(values.fileSize ?? -1)
            guard size == descriptor.byteCount else {
                throw ASHP06RuntimeBundleV4Error.artifactSizeMismatch(
                    role: descriptor.role,
                    expected: descriptor.byteCount,
                    actual: size
                )
            }
            guard size <= trustPolicy.maximumArtifactByteCount else {
                throw ASHP06RuntimeBundleV4Error.artifactTooLarge(
                    role: descriptor.role,
                    byteCount: size
                )
            }
            let (nextTotal, overflow) = totalByteCount.addingReportingOverflow(size)
            guard !overflow, nextTotal <= trustPolicy.maximumBundleByteCount else {
                throw ASHP06RuntimeBundleV4Error.bundleTooLarge(nextTotal)
            }
            totalByteCount = nextTotal
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let actualHash = ASHSHA256V4(rawData: data)
            guard actualHash == descriptor.contentSHA256 else {
                throw ASHP06RuntimeBundleV4Error.artifactHashMismatch(
                    role: descriptor.role,
                    expected: descriptor.contentSHA256,
                    actual: actualHash
                )
            }
            try ASHP06RuntimeBundleBuilderV4.validateArtifactData(
                data,
                role: descriptor.role,
                releaseStatus: manifest.releaseStatus
            )
            if descriptor.role == .metalLibrary {
                do {
                    try metalLibraryValidator.validateExecutableMetalLibrary(data)
                } catch {
                    throw ASHP06RuntimeBundleV4Error.metalLibraryValidationFailed(
                        String(describing: error)
                    )
                }
            }
            loaded[descriptor.role] = data
        }
        let inputs = loaded.map {
            ASHP06RuntimeArtifactInputV4(role: $0.key, data: $0.value)
        }
        try ASHP06RuntimeBundleBuilderV4.validateCrossBindings(
            inputs: inputs,
            manifest: manifest
        )
        let verified = ASHVerifiedRuntimeBundleV4(
            bundleURL: bundle,
            manifest: manifest,
            manifestSHA256: manifestSHA256,
            artifactsByRole: loaded
        )
        try verified.verifyBinding()
        return verified
    }

    private static func regularFiles(
        in bundle: URL,
        fileManager: FileManager
    ) throws -> Set<String> {
        guard let enumerator = fileManager.enumerator(atPath: bundle.path) else {
            throw ASHP06RuntimeBundleV4Error.bundleNotDirectory(bundle.path)
        }
        var files = Set<String>()
        for case let relative as String in enumerator {
            let url = bundle.appendingPathComponent(relative)
            let values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
            )
            if values.isSymbolicLink == true {
                throw ASHP06RuntimeBundleV4Error.symbolicLink(relative)
            }
            if values.isRegularFile == true {
                files.insert(relative)
            } else if values.isDirectory == true {
                guard relative == "artifacts" else {
                    throw ASHP06RuntimeBundleV4Error.unexpectedBundleEntry(
                        relative
                    )
                }
            } else {
                throw ASHP06RuntimeBundleV4Error.unexpectedBundleEntry(relative)
            }
        }
        return files
    }
}
