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
    case benchmarkCorpusIdentityMismatch
    case qualityCorpusIdentityMismatch
    case metricContractMismatch
    case phaseCoefficientProcedureMismatch
    case verificationContractMismatch
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

    func benchmarkCorpusIdentity()
        throws -> ASHP06BenchmarkCorpusIdentityArtifactV4 {
        let artifact = try ASHCanonicalJSONV4.decode(
            ASHP06BenchmarkCorpusIdentityArtifactV4.self,
            from: artifactData(for: .benchmarkCorpusIdentity)
        )
        try artifact.validate()
        return artifact
    }

    func qualityCorpusIdentity()
        throws -> ASHP06QualityCorpusIdentityArtifactV4 {
        let artifact = try ASHCanonicalJSONV4.decode(
            ASHP06QualityCorpusIdentityArtifactV4.self,
            from: artifactData(for: .qualityCorpusIdentity)
        )
        try artifact.validate()
        return artifact
    }

    func metricContract() throws -> ASHP06MetricContractArtifactV4 {
        let artifact = try ASHCanonicalJSONV4.decode(
            ASHP06MetricContractArtifactV4.self,
            from: artifactData(for: .metricContract)
        )
        try artifact.validate(
            qualityCorpusIdentitySHA256: manifest.artifact(
                for: .qualityCorpusIdentity
            ).contentSHA256,
            benchmarkCorpusIdentitySHA256: manifest.artifact(
                for: .benchmarkCorpusIdentity
            ).contentSHA256,
            measurementContractSHA256: manifest.artifact(
                for: .measurementContract
            ).contentSHA256
        )
        return artifact
    }

    func phaseCoefficientProcedure()
        throws -> ASHP06PhaseCoefficientProcedureArtifactV4 {
        let artifact = try ASHCanonicalJSONV4.decode(
            ASHP06PhaseCoefficientProcedureArtifactV4.self,
            from: artifactData(for: .phaseCoefficientProcedure)
        )
        try artifact.validate()
        return artifact
    }

    func verificationContract()
        throws -> ASHP06VerificationContractArtifactV4 {
        let artifact = try ASHCanonicalJSONV4.decode(
            ASHP06VerificationContractArtifactV4.self,
            from: artifactData(for: .verificationContract)
        )
        try artifact.validate(
            benchmarkCorpusIdentitySHA256: manifest.artifact(
                for: .benchmarkCorpusIdentity
            ).contentSHA256,
            qualityCorpusIdentitySHA256: manifest.artifact(
                for: .qualityCorpusIdentity
            ).contentSHA256,
            metricContractSHA256: manifest.artifact(
                for: .metricContract
            ).contentSHA256,
            measurementContractSHA256: manifest.artifact(
                for: .measurementContract
            ).contentSHA256,
            phaseCoefficientProcedureSHA256: manifest.artifact(
                for: .phaseCoefficientProcedure
            ).contentSHA256,
            operatorBankSHA256: manifest.artifact(for: .operatorBank)
                .contentSHA256,
            metalLibrarySHA256: manifest.artifact(for: .metalLibrary)
                .contentSHA256
        )
        return artifact
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

struct ASHP06LockedFileIdentityV4: Codable, Equatable, Sendable {
    let repositoryRelativePath: String
    let byteCount: Int64
    let contentSHA256: ASHSHA256V4
}

enum ASHP06LockedV3EvidenceV4 {
    static let baselineID = "mirmir-v3-p05-baseline-2026-08-02"
    static let captureSourceRevision =
        "d3a4de55c08391ea8a08c00beb766b5650dc9f58"
}

/// Immutable same-scope performance population and evaluator identities. The
/// release report is generated later against the completed P06 candidate; the
/// runtime locks the preregistered workload and measurement procedure so that
/// candidate results cannot redefine the gate.
enum ASHP06LockedPerformanceGateV4 {
    static let gateID =
        "mirmir-deterministic-engine-v4-same-scope-performance-v1"
    static let lockedInputByteCount: Int64 = 1_158
    static let lockedInputSHA256 = try! ASHSHA256V4(
        "1e2d65c2702dc3e47768293cf566ecd105282cb7d4ae58874dc313a77b53182d"
    )

    static func contract() throws -> ASHP06LockedFileIdentityV4 {
        try identity(
            "script/v4/performance-gate-contract-v1.json",
            5_152,
            "42cc36f29a385ba77c50a8aa673ea6808ef98eecf562e6f4742fc89a83729430"
        )
    }

    static func captureImplementation() throws
        -> ASHP06LockedFileIdentityV4 {
        try identity(
            "script/v4/PerformanceGateCaptureTests.swift",
            30_267,
            "8a6acc0b976a5408e2d0ce496b6fb62972607c5ff80039c3e5b102c9a8b04a3b"
        )
    }

    static func evaluatorImplementation() throws
        -> ASHP06LockedFileIdentityV4 {
        try identity(
            "script/v4/performance_gate_v4.py",
            187_072,
            "7e89bf754d6dde082d1cf506750d8912898489929b5a315f62229cad4c29f758"
        )
    }

    static func runnerImplementation() throws
        -> ASHP06LockedFileIdentityV4 {
        try identity(
            "script/v4/run_performance_gate_v4.sh",
            39_826,
            "ebec53b106ad04712f4e266f27ee29157938e28e1e649dd9df81c0a996aa08dc"
        )
    }

    static func lockedInput() throws -> ASHP06LockedFileIdentityV4 {
        try identity(
            "docs/v4/evidence/v3-p05-baseline-2026-08-02/end-to-end-input.mov",
            lockedInputByteCount,
            lockedInputSHA256.rawValue
        )
    }

    static var allLockedFiles: [ASHP06LockedFileIdentityV4] {
        get throws {
            try [
                contract(),
                captureImplementation(),
                evaluatorImplementation(),
                runnerImplementation(),
                lockedInput()
            ]
        }
    }

    private static func identity(
        _ path: String,
        _ byteCount: Int64,
        _ sha256: String
    ) throws -> ASHP06LockedFileIdentityV4 {
        ASHP06LockedFileIdentityV4(
            repositoryRelativePath: path,
            byteCount: byteCount,
            contentSHA256: try ASHSHA256V4(sha256)
        )
    }
}

/// Repository identities that reproduce the release quality population. The
/// corpus pixels are generated outside the runtime, but the immutable lock
/// records the exact natural sources, decoder, construction procedure, case
/// inventory, and resulting artifact-set identity.
enum ASHP06LockedNaturalQualityEvidenceV4 {
    static let corpusID = "ash-v4-seven-cohort-locked-natural-v1"
    static let manifestByteCount: Int64 = 192_662
    static let manifestSHA256 = try! ASHSHA256V4(
        "f999e0607dfac799ee0531804d14c4e6333db3bee20328898498e6a5e9a96896"
    )
    static let artifactSetSHA256 = try! ASHSHA256V4(
        "750cab4072c635f30a925dd7715c1729213f14601855a841fb6d3f32cf1db66e"
    )
    static let sourceAssetSetSHA256 = try! ASHSHA256V4(
        "88556f6bd16c363ae1c76d98d2a6017b78b15da78936b76dfaea7e790488af00"
    )
    static let sourceLicenseSetSHA256 = try! ASHSHA256V4(
        "30ee1b9d1cbb391c2134cfac685d9f7b3da0aa256487ea3ec5466b15abfed345"
    )
    static let decoderExecutableSHA256 = try! ASHSHA256V4(
        "dad4b30b36a1a999bfa4b6ffbde138bd17ee496c69e12eef638227dff2c6415c"
    )

    static func releaseLock() throws -> ASHP06LockedFileIdentityV4 {
        try identity(
            "script/v4/natural-quality-corpus-lock-v1.json",
            1_401,
            "cd4742a52abddc86f2c998802e768c16d0a9bffdb97d49f5e6b3cfcdcdf9c12f"
        )
    }

    static func sourceSelection() throws -> ASHP06LockedFileIdentityV4 {
        try identity(
            "script/v4/natural-quality-sources-v1.json",
            8_558,
            "4c9e1c5a06ab7e679b3ce5954421baef7c509abab164ed91ce5a5031370dd611"
        )
    }

    static func qualityContract() throws -> ASHP06LockedFileIdentityV4 {
        try identity(
            "script/v4/quality-gate-release-contract-v1.json",
            5_997,
            "0b0beceb0a62a5fc1a022adff890b9c546075d03451a4f2cc448521a1cd62a88"
        )
    }

    static func corpusBuilder() throws -> ASHP06LockedFileIdentityV4 {
        try identity(
            "script/v4/build_natural_quality_corpus.py",
            19_178,
            "0150955cfa206bf9e4b3f3ca7b74971543e70d4ec47d4f174eb87b1e33790aa8"
        )
    }

    static func metricImplementation() throws -> ASHP06LockedFileIdentityV4 {
        try identity(
            "script/v4/quality_gate_v4.py",
            80_068,
            "7ccd36727d705420b007203cb281acde37058b1f94fef8d8be3e06c8bc0a03eb"
        )
    }

    static func captureImplementation() throws -> ASHP06LockedFileIdentityV4 {
        try identity(
            "Mirmir/App/MirmirApp.swift",
            342_264,
            "9fcf2009a18385524f65644cf13e744a0cdd58550808bc43089dff4f12f98a84"
        )
    }

    static func runnerImplementation() throws -> ASHP06LockedFileIdentityV4 {
        try identity(
            "script/v4/run_quality_gate_v4.sh",
            14_630,
            "d4d06e4a72a506421307a6f0963a44abc157c1cf1bc80101536a13b25600e3cb"
        )
    }

    static var allLockedFiles: [ASHP06LockedFileIdentityV4] {
        get throws {
            try [
                releaseLock(),
                sourceSelection(),
                qualityContract(),
                corpusBuilder(),
                metricImplementation(),
                captureImplementation(),
                runnerImplementation()
            ]
        }
    }

    private static func identity(
        _ path: String,
        _ byteCount: Int64,
        _ sha256: String
    ) throws -> ASHP06LockedFileIdentityV4 {
        ASHP06LockedFileIdentityV4(
            repositoryRelativePath: path,
            byteCount: byteCount,
            contentSHA256: try ASHSHA256V4(sha256)
        )
    }
}

struct ASHP06BenchmarkRouteIdentityV4: Codable, Equatable, Sendable {
    let caseID: String
    let backendID: String
    let pixelFormatID: String
    let sourceWidth: Int
    let sourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int
    let scaleNumerator: Int
    let scaleDenominator: Int
    let warmupCount: Int
    let measuredSampleCount: Int
}

struct ASHP06BenchmarkCorpusIdentityArtifactV4: Codable, Equatable, Sendable {
    let schemaID: String
    let artifactRole: String
    let corpusID: String
    let baselineID: String
    let baselineSourceRevision: String
    let baselineImplementationVersions: [String]
    let performanceContract: ASHP06LockedFileIdentityV4
    let captureImplementation: ASHP06LockedFileIdentityV4
    let evaluatorImplementation: ASHP06LockedFileIdentityV4
    let runnerImplementation: ASHP06LockedFileIdentityV4
    let lockedInput: ASHP06LockedFileIdentityV4
    let inputFrameCount: Int
    let inputCodecID: String
    let outputCodecID: String
    let routes: [ASHP06BenchmarkRouteIdentityV4]
    let requiredStatistics: [String]
    let comparabilityRuleID: String

    static func canonical() throws -> Self {
        let routes = [
            ("nv12-video-range-2x-cpu", "mirmirDeterministicCPU", 128, 96, 2, 1),
            ("nv12-video-range-2x-metal", "mirmirDeterministicMetal", 128, 96, 2, 1),
            ("nv12-video-range-3-over-2-cpu", "mirmirDeterministicCPU", 96, 72, 3, 2),
            ("nv12-video-range-3-over-2-metal", "mirmirDeterministicMetal", 96, 72, 3, 2)
        ].map { id, backend, width, height, numerator, denominator in
            ASHP06BenchmarkRouteIdentityV4(
                caseID: id,
                backendID: backend,
                pixelFormatID: "420v",
                sourceWidth: 64,
                sourceHeight: 48,
                targetWidth: width,
                targetHeight: height,
                scaleNumerator: numerator,
                scaleDenominator: denominator,
                warmupCount: 5,
                measuredSampleCount: 10
            )
        }
        return Self(
            schemaID: ASHRuntimeArtifactRoleV4.benchmarkCorpusIdentity
                .expectedSchemaID,
            artifactRole:
                ASHRuntimeArtifactRoleV4.benchmarkCorpusIdentity.rawValue,
            corpusID: ASHP06LockedPerformanceGateV4.gateID,
            baselineID: ASHP06LockedV3EvidenceV4.baselineID,
            baselineSourceRevision:
                ASHP06LockedV3EvidenceV4.captureSourceRevision,
            baselineImplementationVersions: [
                "ash-p05-cpu-reference-preview",
                "ash-p05-metal-v3-preview"
            ],
            performanceContract:
                try ASHP06LockedPerformanceGateV4.contract(),
            captureImplementation:
                try ASHP06LockedPerformanceGateV4.captureImplementation(),
            evaluatorImplementation:
                try ASHP06LockedPerformanceGateV4.evaluatorImplementation(),
            runnerImplementation:
                try ASHP06LockedPerformanceGateV4.runnerImplementation(),
            lockedInput: try ASHP06LockedPerformanceGateV4.lockedInput(),
            inputFrameCount: 3,
            inputCodecID: "avc1",
            outputCodecID: "avc1",
            routes: routes,
            requiredStatistics: [
                "aggregate-corpus-wall-median",
                "engine-frame-median",
                "engine-frame-p95",
                "paired-bootstrap-95-percent-upper-bound"
            ],
            comparabilityRuleID:
                "same-input-target-codec-hardware-software-power-thermal-v1"
        )
    }

    func validate() throws {
        guard self == (try Self.canonical()) else {
            throw ASHP06RuntimeBundleV4Error
                .benchmarkCorpusIdentityMismatch
        }
    }
}

struct ASHP06QualityCorpusIdentityArtifactV4: Codable, Equatable, Sendable {
    let schemaID: String
    let artifactRole: String
    let corpusID: String
    let baselineID: String
    let baselineSourceRevision: String
    let baselineImplementationVersions: [String]
    let releaseLock: ASHP06LockedFileIdentityV4
    let sourceSelection: ASHP06LockedFileIdentityV4
    let qualityContract: ASHP06LockedFileIdentityV4
    let corpusBuilder: ASHP06LockedFileIdentityV4
    let captureImplementation: ASHP06LockedFileIdentityV4
    let runnerImplementation: ASHP06LockedFileIdentityV4
    let manifestByteCount: Int64
    let manifestSHA256: ASHSHA256V4
    let artifactSetSHA256: ASHSHA256V4
    let sourceAssetSetSHA256: ASHSHA256V4
    let sourceLicenseSetSHA256: ASHSHA256V4
    let decoderExecutableSHA256: ASHSHA256V4
    let decoderVersion: String
    let decodeProcedureID: String
    let pixelStorageIDs: [String]
    let orderedCohortIDs: [String]
    let clipCount: Int
    let caseCount: Int
    let framesPerClip: Int
    let primaryScaleNumerator: Int
    let primaryScaleDenominator: Int
    let releaseEligible: Bool

    static func canonical() throws -> Self {
        Self(
            schemaID: ASHRuntimeArtifactRoleV4.qualityCorpusIdentity
                .expectedSchemaID,
            artifactRole: ASHRuntimeArtifactRoleV4.qualityCorpusIdentity.rawValue,
            corpusID: ASHP06LockedNaturalQualityEvidenceV4.corpusID,
            baselineID: ASHP06LockedV3EvidenceV4.baselineID,
            baselineSourceRevision:
                ASHP06LockedV3EvidenceV4.captureSourceRevision,
            baselineImplementationVersions: [
                "ash-p05-cpu-reference-preview",
                "ash-p05-metal-v3-preview"
            ],
            releaseLock:
                try ASHP06LockedNaturalQualityEvidenceV4.releaseLock(),
            sourceSelection:
                try ASHP06LockedNaturalQualityEvidenceV4.sourceSelection(),
            qualityContract:
                try ASHP06LockedNaturalQualityEvidenceV4.qualityContract(),
            corpusBuilder:
                try ASHP06LockedNaturalQualityEvidenceV4.corpusBuilder(),
            captureImplementation:
                try ASHP06LockedNaturalQualityEvidenceV4
                    .captureImplementation(),
            runnerImplementation:
                try ASHP06LockedNaturalQualityEvidenceV4
                    .runnerImplementation(),
            manifestByteCount:
                ASHP06LockedNaturalQualityEvidenceV4.manifestByteCount,
            manifestSHA256:
                ASHP06LockedNaturalQualityEvidenceV4.manifestSHA256,
            artifactSetSHA256:
                ASHP06LockedNaturalQualityEvidenceV4.artifactSetSHA256,
            sourceAssetSetSHA256:
                ASHP06LockedNaturalQualityEvidenceV4.sourceAssetSetSHA256,
            sourceLicenseSetSHA256:
                ASHP06LockedNaturalQualityEvidenceV4.sourceLicenseSetSHA256,
            decoderExecutableSHA256:
                ASHP06LockedNaturalQualityEvidenceV4.decoderExecutableSHA256,
            decoderVersion:
                "ffmpeg version 8.1.2 Copyright (c) 2000-2026 the FFmpeg developers",
            decodeProcedureID:
                "ffmpeg-accurate-input-seek-rgb24-center-crop-lanczos-v1",
            pixelStorageIDs: [
                "nv12_full_range_8_bit",
                "nv12_video_range_8_bit"
            ],
            orderedCohortIDs: [
                "natural_detail",
                "text_graphics",
                "animation",
                "faces",
                "low_light_noise",
                "high_motion",
                "scene_cuts"
            ],
            clipCount: 28,
            caseCount: 168,
            framesPerClip: 6,
            primaryScaleNumerator: 2,
            primaryScaleDenominator: 1,
            releaseEligible: true
        )
    }

    func validate() throws {
        guard self == (try Self.canonical()) else {
            throw ASHP06RuntimeBundleV4Error.qualityCorpusIdentityMismatch
        }
    }
}

enum ASHP06QualityMetricComponentV4: String, Codable, CaseIterable,
    Sendable {
    case chromaMultiscaleStructuralError =
        "chroma_multiscale_structural_error"
    case edgeRingingError = "edge_displacement_ringing_overshoot_error"
    case lumaMultiscaleStructuralError = "luma_multiscale_structural_error"
    case perceptualFeatureError = "perceptual_feature_distance"
    case temporalFlickerError =
        "motion_compensated_temporal_flicker_error"
}

struct ASHP06QualityMetricWeightV4: Codable, Equatable, Sendable {
    let component: ASHP06QualityMetricComponentV4
    let weight: ExactRationalV4
}

struct ASHP06MetricContractArtifactV4: Codable, Equatable, Sendable {
    let schemaID: String
    let artifactRole: String
    let contractID: String
    let qualityCorpusIdentitySHA256: ASHSHA256V4
    let benchmarkCorpusIdentitySHA256: ASHSHA256V4
    let measurementContractSHA256: ASHSHA256V4
    let metricImplementationSource: ASHP06LockedFileIdentityV4
    let qualityWeights: [ASHP06QualityMetricWeightV4]
    let qualityIndexFormulaID: String
    let baselineQualityIndex: Int
    let minimumQualityIndex: Int
    let pairedBootstrapConfidence: ExactRationalV4
    let minimumQualityConfidenceLowerBound: Int
    let maximumLumaCohortRegression: ExactRationalV4
    let temporalCohortRegressionAllowed: Bool
    let maximumProcessingTimeRatio: ExactRationalV4
    let requiredTimeStatistics: [String]
    let exactConformanceDomains: [String]

    static func canonical(
        qualityCorpusIdentitySHA256: ASHSHA256V4,
        benchmarkCorpusIdentitySHA256: ASHSHA256V4,
        measurementContractSHA256: ASHSHA256V4
    ) throws -> Self {
        Self(
            schemaID: ASHRuntimeArtifactRoleV4.metricContract.expectedSchemaID,
            artifactRole: ASHRuntimeArtifactRoleV4.metricContract.rawValue,
            contractID: "ash-p06-quality-performance-metric-contract-v2",
            qualityCorpusIdentitySHA256: qualityCorpusIdentitySHA256,
            benchmarkCorpusIdentitySHA256: benchmarkCorpusIdentitySHA256,
            measurementContractSHA256: measurementContractSHA256,
            metricImplementationSource:
                try ASHP06LockedNaturalQualityEvidenceV4
                    .metricImplementation(),
            qualityWeights: [
                ASHP06QualityMetricWeightV4(
                    component: .chromaMultiscaleStructuralError,
                    weight: try ExactRationalV4(15, 100)
                ),
                ASHP06QualityMetricWeightV4(
                    component: .edgeRingingError,
                    weight: try ExactRationalV4(10, 100)
                ),
                ASHP06QualityMetricWeightV4(
                    component: .lumaMultiscaleStructuralError,
                    weight: try ExactRationalV4(35, 100)
                ),
                ASHP06QualityMetricWeightV4(
                    component: .perceptualFeatureError,
                    weight: try ExactRationalV4(20, 100)
                ),
                ASHP06QualityMetricWeightV4(
                    component: .temporalFlickerError,
                    weight: try ExactRationalV4(20, 100)
                )
            ],
            qualityIndexFormulaID:
                "q-ash-equals-100-times-open-2-minus-normalized-error-close-v1",
            baselineQualityIndex: 100,
            minimumQualityIndex: 105,
            pairedBootstrapConfidence: try ExactRationalV4(95, 100),
            minimumQualityConfidenceLowerBound: 105,
            maximumLumaCohortRegression: try ExactRationalV4(1, 100),
            temporalCohortRegressionAllowed: false,
            maximumProcessingTimeRatio: try ExactRationalV4(80, 100),
            requiredTimeStatistics: [
                "aggregate-wall-median",
                "engine-frame-median",
                "engine-frame-p95"
            ],
            exactConformanceDomains: [
                "alpha",
                "geometry",
                "metadata",
                "pixel-range"
            ]
        )
    }

    func validate(
        qualityCorpusIdentitySHA256: ASHSHA256V4,
        benchmarkCorpusIdentitySHA256: ASHSHA256V4,
        measurementContractSHA256: ASHSHA256V4
    ) throws {
        guard self == (try Self.canonical(
            qualityCorpusIdentitySHA256: qualityCorpusIdentitySHA256,
            benchmarkCorpusIdentitySHA256: benchmarkCorpusIdentitySHA256,
            measurementContractSHA256: measurementContractSHA256
        )) else {
            throw ASHP06RuntimeBundleV4Error.metricContractMismatch
        }
    }
}

enum ASHP06FixedPointSourceIdentityV4 {
    static func spatialScalePlan() throws -> ASHP06LockedFileIdentityV4 {
        try identity(
            "Mirmir/Modules/UpscalerEngine/SpatialScalePlanV4.swift",
            10_953,
            "04eb8a6d960e8cbf95ab98d3b3f1baf5bb3826741dfb2dc242de1bda9ca5774e"
        )
    }

    static func fixedPointKernel() throws -> ASHP06LockedFileIdentityV4 {
        try identity(
            "Mirmir/Modules/UpscalerEngine/FixedPointKernelV4.swift",
            57_116,
            "1f3a23168eecb881db0daf63cda3475572a82b9b611876ef1742c9efaa4debe6"
        )
    }

    static func metalKernel() throws -> ASHP06LockedFileIdentityV4 {
        try identity(
            "Mirmir/Modules/UpscalerEngine/FixedPointMetalKernelsV4.metal",
            3_938,
            "38952b9387b440adc5857c0b1f5f915a723aec776bf16f4338eb78c7e2dcc8f8"
        )
    }

    static func metalExecutor() throws -> ASHP06LockedFileIdentityV4 {
        try identity(
            "Mirmir/Modules/UpscalerEngine/FixedPointMetalExecutorV4.swift",
            37_622,
            "96589e1d3c7c53780f56af05cd0c8f9782fc942d8a6f8ac1e902ebe5258fc157"
        )
    }

    static var allLockedFiles: [ASHP06LockedFileIdentityV4] {
        get throws {
            try [
                spatialScalePlan(),
                fixedPointKernel(),
                metalKernel(),
                metalExecutor()
            ]
        }
    }

    private static func identity(
        _ path: String,
        _ byteCount: Int64,
        _ sha256: String
    ) throws -> ASHP06LockedFileIdentityV4 {
        ASHP06LockedFileIdentityV4(
            repositoryRelativePath: path,
            byteCount: byteCount,
            contentSHA256: try ASHSHA256V4(sha256)
        )
    }
}

struct ASHP06PhaseCoefficientProcedureArtifactV4: Codable, Equatable,
    Sendable {
    let schemaID: String
    let artifactRole: String
    let kernelContractID: String
    let coordinateProcedureID: String
    let coefficientProcedureID: String
    let spatialScalePlanSource: ASHP06LockedFileIdentityV4
    let fixedPointKernelSource: ASHP06LockedFileIdentityV4
    let metalKernelSource: ASHP06LockedFileIdentityV4
    let metalExecutorSource: ASHP06LockedFileIdentityV4
    let tapOffsets: [Int]
    let fractionalBits: Int
    let normalization: Int32
    let coefficientRoundingRuleID: String
    let equalRemainderTapOrderLeftHalf: [Int]
    let equalRemainderTapOrderRightHalf: [Int]
    let separableIntermediateRounding: Bool
    let finalAccumulatorFractionalBits: Int
    let finalRoundingRule: FixedPointRoundingRuleV4
    let accumulatorBitWidth: Int
    let clampStageID: String
    let admittedBorderRules: [SpatialBorderRuleV4]
    let metalEntryPoint: String

    static func canonical() throws -> Self {
        Self(
            schemaID: ASHRuntimeArtifactRoleV4.phaseCoefficientProcedure
                .expectedSchemaID,
            artifactRole:
                ASHRuntimeArtifactRoleV4.phaseCoefficientProcedure.rawValue,
            kernelContractID: FixedPointCoefficientCompilerV4.procedureID,
            coordinateProcedureID:
                "pixel-center-2j-plus-1-times-s-minus-t-over-2t-v1",
            coefficientProcedureID: FixedPointCoefficientCompilerV4.procedureID,
            spatialScalePlanSource:
                try ASHP06FixedPointSourceIdentityV4.spatialScalePlan(),
            fixedPointKernelSource:
                try ASHP06FixedPointSourceIdentityV4.fixedPointKernel(),
            metalKernelSource:
                try ASHP06FixedPointSourceIdentityV4.metalKernel(),
            metalExecutorSource:
                try ASHP06FixedPointSourceIdentityV4.metalExecutor(),
            tapOffsets: FixedPointPhaseKernelV4.tapOffsets,
            fractionalBits: FixedPointCoefficientCompilerV4.fractionalBits,
            normalization: FixedPointCoefficientCompilerV4.normalization,
            coefficientRoundingRuleID:
                "largest-remainder-descending-fraction-phase-half-total-tie-v1",
            equalRemainderTapOrderLeftHalf: [1, 2, 0, 3],
            equalRemainderTapOrderRightHalf: [2, 1, 3, 0],
            separableIntermediateRounding: false,
            finalAccumulatorFractionalBits:
                FixedPointCoefficientCompilerV4.fractionalBits * 2,
            finalRoundingRule: .nearestTiesToEven,
            accumulatorBitWidth: 64,
            clampStageID: "after-final-q28-reduction",
            admittedBorderRules: [.clamp, .reflect101],
            metalEntryPoint: "ashFixedPointScaleV4"
        )
    }

    func validate() throws {
        guard self == (try Self.canonical()) else {
            throw ASHP06RuntimeBundleV4Error
                .phaseCoefficientProcedureMismatch
        }
    }
}

enum ASHP06VerificationRuleContractV4: String, Codable, CaseIterable,
    Sendable {
    case alphaIdentity = "alpha_identity"
    case attachmentSemantics = "attachment_semantics"
    case approvedDropRecord = "approved_drop_record"
    case colorSemantics = "color_semantics"
    case containerReadability = "container_readability"
    case duration
    case encodedSampleIdentity = "encoded_sample_identity"
    case exactPresentationGeometry = "exact_presentation_geometry"
    case metadataSemantics = "metadata_semantics"
    case noUnplannedDrops = "no_unplanned_drops"
    case pixelLayout = "pixel_layout"
    case runtimeIdentity = "runtime_identity"
    case scanSemantics = "scan_semantics"
    case timingAndEditLists = "timing_and_edit_lists"
    case trackIdentityAndOrdering = "track_identity_and_ordering"
    case visiblePixelBytes = "visible_pixel_bytes"
}

enum ASHP06VerificationSourceIdentityV4 {
    static func executionPlan() throws -> ASHP06LockedFileIdentityV4 {
        ASHP06LockedFileIdentityV4(
            repositoryRelativePath:
                "Mirmir/Modules/UpscalerEngine/ASH/ASHExecutionPlanV4.swift",
            byteCount: 20_377,
            contentSHA256: try ASHSHA256V4(
                "f84ef84e038ecade76a550f9ca235913b109c8b9d47bbefff9e7578d9e50a0f2"
            )
        )
    }
}

struct ASHP06VerificationContractArtifactV4: Codable, Equatable, Sendable {
    let schemaID: String
    let artifactRole: String
    let contractID: String
    let benchmarkCorpusIdentitySHA256: ASHSHA256V4
    let qualityCorpusIdentitySHA256: ASHSHA256V4
    let metricContractSHA256: ASHSHA256V4
    let measurementContractSHA256: ASHSHA256V4
    let phaseCoefficientProcedureSHA256: ASHSHA256V4
    let operatorBankSHA256: ASHSHA256V4
    let metalLibrarySHA256: ASHSHA256V4
    let verificationImplementationSource: ASHP06LockedFileIdentityV4
    let requiredRules: [ASHP06VerificationRuleContractV4]
    let visiblePixelMismatchAllowance: Int
    let cpuMetalByteIdentityRequired: Bool
    let repeatedRunIdentityRequired: Bool
    let crossProcessIdentityRequired: Bool
    let everyEnabledTrackRequiresDisposition: Bool
    let unapprovedDropsAllowed: Bool
    let verificationFailureDispositionID: String

    static func canonical(
        benchmarkCorpusIdentitySHA256: ASHSHA256V4,
        qualityCorpusIdentitySHA256: ASHSHA256V4,
        metricContractSHA256: ASHSHA256V4,
        measurementContractSHA256: ASHSHA256V4,
        phaseCoefficientProcedureSHA256: ASHSHA256V4,
        operatorBankSHA256: ASHSHA256V4,
        metalLibrarySHA256: ASHSHA256V4
    ) throws -> Self {
        Self(
            schemaID: ASHRuntimeArtifactRoleV4.verificationContract
                .expectedSchemaID,
            artifactRole:
                ASHRuntimeArtifactRoleV4.verificationContract.rawValue,
            contractID: "ash-p06-fail-closed-verification-contract-v1",
            benchmarkCorpusIdentitySHA256: benchmarkCorpusIdentitySHA256,
            qualityCorpusIdentitySHA256: qualityCorpusIdentitySHA256,
            metricContractSHA256: metricContractSHA256,
            measurementContractSHA256: measurementContractSHA256,
            phaseCoefficientProcedureSHA256:
                phaseCoefficientProcedureSHA256,
            operatorBankSHA256: operatorBankSHA256,
            metalLibrarySHA256: metalLibrarySHA256,
            verificationImplementationSource:
                try ASHP06VerificationSourceIdentityV4.executionPlan(),
            requiredRules: ASHP06VerificationRuleContractV4.allCases.sorted {
                $0.rawValue < $1.rawValue
            },
            visiblePixelMismatchAllowance: 0,
            cpuMetalByteIdentityRequired: true,
            repeatedRunIdentityRequired: true,
            crossProcessIdentityRequired: true,
            everyEnabledTrackRequiresDisposition: true,
            unapprovedDropsAllowed: false,
            verificationFailureDispositionID: "fail-job-before-commit"
        )
    }

    func validate(
        benchmarkCorpusIdentitySHA256: ASHSHA256V4,
        qualityCorpusIdentitySHA256: ASHSHA256V4,
        metricContractSHA256: ASHSHA256V4,
        measurementContractSHA256: ASHSHA256V4,
        phaseCoefficientProcedureSHA256: ASHSHA256V4,
        operatorBankSHA256: ASHSHA256V4,
        metalLibrarySHA256: ASHSHA256V4
    ) throws {
        guard self == (try Self.canonical(
            benchmarkCorpusIdentitySHA256: benchmarkCorpusIdentitySHA256,
            qualityCorpusIdentitySHA256: qualityCorpusIdentitySHA256,
            metricContractSHA256: metricContractSHA256,
            measurementContractSHA256: measurementContractSHA256,
            phaseCoefficientProcedureSHA256:
                phaseCoefficientProcedureSHA256,
            operatorBankSHA256: operatorBankSHA256,
            metalLibrarySHA256: metalLibrarySHA256
        )) else {
            throw ASHP06RuntimeBundleV4Error.verificationContractMismatch
        }
    }
}

struct ASHP06MetalCompilerContractArtifactV4: Codable, Equatable, Sendable {
    let schemaID: String
    let artifactRole: String
    let metalLibrarySHA256: ASHSHA256V4
    let compilerExecutableID: String
    let linkerExecutableID: String
    let compilerIdentity: String
    let languageVersion: String
    let sdkBuildIdentity: String
    let deploymentTarget: String
    let targetTriple: String
    let metalSourceSHA256: ASHSHA256V4
    let compilerArgumentTemplate: [String]
    let linkerArgumentTemplate: [String]
    let entryPointNames: [String]

    static func canonical(
        metalLibrarySHA256: ASHSHA256V4,
        phaseProcedure: ASHP06PhaseCoefficientProcedureArtifactV4,
        toolchain: ASHRuntimeToolchainV4
    ) -> Self {
        let minimumOSVersion = toolchain.deploymentTarget.hasPrefix("macos-")
            ? String(toolchain.deploymentTarget.dropFirst("macos-".count))
            : toolchain.deploymentTarget
        return Self(
            schemaID: ASHRuntimeArtifactRoleV4.metalCompilerContract
                .expectedSchemaID,
            artifactRole:
                ASHRuntimeArtifactRoleV4.metalCompilerContract.rawValue,
            metalLibrarySHA256: metalLibrarySHA256,
            compilerExecutableID: "xcrun-sdk-macosx-metal",
            linkerExecutableID: "xcrun-sdk-macosx-metallib",
            compilerIdentity: toolchain.metalCompilerIdentity,
            languageVersion: toolchain.metalLanguageVersion,
            sdkBuildIdentity: toolchain.sdkBuildIdentity,
            deploymentTarget: toolchain.deploymentTarget,
            targetTriple: toolchain.targetTriple,
            metalSourceSHA256: phaseProcedure.metalKernelSource.contentSHA256,
            compilerArgumentTemplate: [
                "-c",
                "-mmacosx-version-min=\(minimumOSVersion)",
                "-std=\(toolchain.metalLanguageVersion)",
                "{source}",
                "-o",
                "{air}"
            ],
            linkerArgumentTemplate: ["{air}", "-o", "{metallib}"],
            entryPointNames: [phaseProcedure.metalEntryPoint]
        )
    }

    func validate(
        provenance: ASHRuntimeProvenanceV4,
        phaseProcedure: ASHP06PhaseCoefficientProcedureArtifactV4
    ) throws {
        guard self == Self.canonical(
            metalLibrarySHA256: provenance.metalLibrarySHA256,
            phaseProcedure: phaseProcedure,
            toolchain: provenance.toolchain
        ) else {
            throw ASHP06RuntimeBundleV4Error.metalCompilerBindingMismatch
        }
    }
}

enum ASHP06CanonicalRuntimeArtifactsV4 {
    static func make(
        metalLibrary: Data,
        toolchain: ASHRuntimeToolchainV4
    ) throws -> [ASHP06RuntimeArtifactInputV4] {
        let codewords = ASHP06CodewordTablesArtifactV4.canonical()
        let codewordInput = try input(.codewordTables, codewords)
        let certificate = ASHP06CoreCertificateArtifactV4.canonical(
            codewordTablesSHA256: ASHSHA256V4(rawData: codewordInput.data)
        )
        let measurement = try ASHP06MeasurementContractArtifactV4.canonical()
        let measurementInput = try input(.measurementContract, measurement)
        let branch = try ASHP06BranchAggregationArtifactV4.canonical()
        let branchInput = try input(.branchAggregation, branch)
        let operatorBank = ASHP06OperatorBankArtifactV4.canonical(
            branchProgramSHA256: branch.canonicalBinarySHA256
        )
        let operatorInput = try input(.operatorBank, operatorBank)
        let benchmark = try ASHP06BenchmarkCorpusIdentityArtifactV4.canonical()
        let benchmarkInput = try input(.benchmarkCorpusIdentity, benchmark)
        let quality = try ASHP06QualityCorpusIdentityArtifactV4.canonical()
        let qualityInput = try input(.qualityCorpusIdentity, quality)
        let phase = try ASHP06PhaseCoefficientProcedureArtifactV4.canonical()
        let phaseInput = try input(.phaseCoefficientProcedure, phase)
        let metric = try ASHP06MetricContractArtifactV4.canonical(
            qualityCorpusIdentitySHA256: ASHSHA256V4(
                rawData: qualityInput.data
            ),
            benchmarkCorpusIdentitySHA256: ASHSHA256V4(
                rawData: benchmarkInput.data
            ),
            measurementContractSHA256: ASHSHA256V4(
                rawData: measurementInput.data
            )
        )
        let metricInput = try input(.metricContract, metric)
        let metalHash = ASHSHA256V4(rawData: metalLibrary)
        let metalContract = ASHP06MetalCompilerContractArtifactV4.canonical(
            metalLibrarySHA256: metalHash,
            phaseProcedure: phase,
            toolchain: toolchain
        )
        let metalContractInput = try input(
            .metalCompilerContract,
            metalContract
        )
        let verification = try ASHP06VerificationContractArtifactV4.canonical(
            benchmarkCorpusIdentitySHA256: ASHSHA256V4(
                rawData: benchmarkInput.data
            ),
            qualityCorpusIdentitySHA256: ASHSHA256V4(
                rawData: qualityInput.data
            ),
            metricContractSHA256: ASHSHA256V4(rawData: metricInput.data),
            measurementContractSHA256: ASHSHA256V4(
                rawData: measurementInput.data
            ),
            phaseCoefficientProcedureSHA256: ASHSHA256V4(
                rawData: phaseInput.data
            ),
            operatorBankSHA256: ASHSHA256V4(rawData: operatorInput.data),
            metalLibrarySHA256: metalHash
        )
        return [
            benchmarkInput,
            branchInput,
            codewordInput,
            try input(.coreCertificate, certificate),
            measurementInput,
            metalContractInput,
            ASHP06RuntimeArtifactInputV4(
                role: .metalLibrary,
                data: metalLibrary
            ),
            metricInput,
            operatorInput,
            phaseInput,
            qualityInput,
            try input(.verificationContract, verification)
        ].sorted { $0.role < $1.role }
    }

    static func validateLockedRepositoryInputs(
        repositoryRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let identities = try ASHP06LockedPerformanceGateV4.allLockedFiles
            + ASHP06LockedNaturalQualityEvidenceV4.allLockedFiles
            + ASHP06FixedPointSourceIdentityV4.allLockedFiles
            + [ASHP06VerificationSourceIdentityV4.executionPlan()]
        for identity in identities {
            let url = repositoryRoot.appendingPathComponent(
                identity.repositoryRelativePath,
                isDirectory: false
            )
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == identity.byteCount else {
                throw ASHP06RuntimeBundleV4Error.invalidBuildInput(
                    "locked input size/type mismatch: \(identity.repositoryRelativePath)"
                )
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard ASHSHA256V4(rawData: data) == identity.contentSHA256 else {
                throw ASHP06RuntimeBundleV4Error.invalidBuildInput(
                    "locked input hash mismatch: \(identity.repositoryRelativePath)"
                )
            }
        }
    }

    private static func input<T: Encodable>(
        _ role: ASHRuntimeArtifactRoleV4,
        _ document: T
    ) throws -> ASHP06RuntimeArtifactInputV4 {
        ASHP06RuntimeArtifactInputV4(
            role: role,
            data: try ASHCanonicalJSONV4.encode(document)
        )
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
           let text = String(data: data, encoding: .utf8)?.lowercased() {
            let isBaselineIdentity = role == .benchmarkCorpusIdentity
                || role == .qualityCorpusIdentity
            if (!isBaselineIdentity
                && (text.contains("p05") || text.contains("preview")))
                || text.contains("development") {
                throw ASHP06RuntimeBundleV4Error.forbiddenPreviewArtifact(role)
            }
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
        let benchmarkData = byRole[.benchmarkCorpusIdentity]!
        let benchmark = try ASHCanonicalJSONV4.decode(
            ASHP06BenchmarkCorpusIdentityArtifactV4.self,
            from: benchmarkData
        )
        try benchmark.validate()
        let qualityData = byRole[.qualityCorpusIdentity]!
        let quality = try ASHCanonicalJSONV4.decode(
            ASHP06QualityCorpusIdentityArtifactV4.self,
            from: qualityData
        )
        try quality.validate()
        let phaseData = byRole[.phaseCoefficientProcedure]!
        let phase = try ASHCanonicalJSONV4.decode(
            ASHP06PhaseCoefficientProcedureArtifactV4.self,
            from: phaseData
        )
        try phase.validate()
        let metricData = byRole[.metricContract]!
        let metric = try ASHCanonicalJSONV4.decode(
            ASHP06MetricContractArtifactV4.self,
            from: metricData
        )
        try metric.validate(
            qualityCorpusIdentitySHA256: ASHSHA256V4(rawData: qualityData),
            benchmarkCorpusIdentitySHA256: ASHSHA256V4(rawData: benchmarkData),
            measurementContractSHA256: ASHSHA256V4(
                rawData: byRole[.measurementContract]!
            )
        )
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
        try metalContract.validate(
            provenance: manifest.provenance,
            phaseProcedure: phase
        )
        let verification = try ASHCanonicalJSONV4.decode(
            ASHP06VerificationContractArtifactV4.self,
            from: byRole[.verificationContract]!
        )
        try verification.validate(
            benchmarkCorpusIdentitySHA256: ASHSHA256V4(rawData: benchmarkData),
            qualityCorpusIdentitySHA256: ASHSHA256V4(rawData: qualityData),
            metricContractSHA256: ASHSHA256V4(rawData: metricData),
            measurementContractSHA256: ASHSHA256V4(
                rawData: byRole[.measurementContract]!
            ),
            phaseCoefficientProcedureSHA256: ASHSHA256V4(rawData: phaseData),
            operatorBankSHA256: ASHSHA256V4(
                rawData: byRole[.operatorBank]!
            ),
            metalLibrarySHA256: manifest.provenance.metalLibrarySHA256
        )
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
