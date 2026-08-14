import Foundation

enum ASHRuntimeManifestV4Error: Error, Equatable, Sendable {
    case unsupportedManifestSchema(String)
    case invalidRuntimeIdentity(String)
    case invalidProvenance(String)
    case forbiddenPreviewIdentity(String)
    case incompleteArtifacts(missing: [ASHRuntimeArtifactRoleV4])
    case unexpectedArtifacts(extra: [ASHRuntimeArtifactRoleV4])
    case duplicateArtifactRole(ASHRuntimeArtifactRoleV4)
    case duplicateArtifactPath(String)
    case nonCanonicalArtifactOrdering
    case invalidArtifactPath(String)
    case invalidArtifactSchema(
        role: ASHRuntimeArtifactRoleV4,
        expected: String,
        actual: String
    )
    case invalidArtifactSize(role: ASHRuntimeArtifactRoleV4, byteCount: Int64)
    case metalLibraryProvenanceMismatch
}

enum ASHRuntimeReleaseStatusV4: String, Codable, Hashable, Sendable {
    case semanticCandidate = "semantic_candidate"
    case releaseQualified = "release_qualified"
}

enum ASHRuntimeArtifactRoleV4: String, Codable, CaseIterable, Comparable,
    Hashable, Sendable {
    case benchmarkCorpusIdentity = "benchmark_corpus_identity"
    case branchAggregation = "branch_aggregation"
    case codewordTables = "codeword_tables"
    case coreCertificate = "core_certificate"
    case measurementContract = "measurement_contract"
    case metalCompilerContract = "metal_compiler_contract"
    case metalLibrary = "metal_library"
    case metricContract = "metric_contract"
    case operatorBank = "operator_bank"
    case phaseCoefficientProcedure = "phase_coefficient_procedure"
    case qualityCorpusIdentity = "quality_corpus_identity"
    case verificationContract = "verification_contract"

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var expectedSchemaID: String {
        switch self {
        case .benchmarkCorpusIdentity:
            "ash.p06.benchmark-corpus-identity.v1"
        case .branchAggregation:
            "ash.p06.branch-aggregation.v1"
        case .codewordTables:
            "ash.p06.codeword-tables.v1"
        case .coreCertificate:
            "ash.p06.core-certificate.v1"
        case .measurementContract:
            "ash.p06.measurement-contract.v1"
        case .metalCompilerContract:
            "ash.p06.metal-compiler-contract.v1"
        case .metalLibrary:
            "com.apple.metallib.p06.v1"
        case .metricContract:
            "ash.p06.metric-contract.v1"
        case .operatorBank:
            "ash.p06.operator-bank.v1"
        case .phaseCoefficientProcedure:
            "ash.p06.phase-coefficient-procedure.v1"
        case .qualityCorpusIdentity:
            "ash.p06.quality-corpus-identity.v1"
        case .verificationContract:
            "ash.p06.verification-contract.v1"
        }
    }

    var canonicalRelativePath: String {
        switch self {
        case .metalLibrary:
            "artifacts/ash-p06.metallib"
        default:
            "artifacts/\(rawValue).json"
        }
    }

    var isCanonicalJSON: Bool { self != .metalLibrary }
}

struct ASHRuntimeArtifactV4: Codable, Equatable, Hashable, Sendable {
    let role: ASHRuntimeArtifactRoleV4
    let relativePath: String
    let schemaID: String
    let contentSHA256: ASHSHA256V4
    let byteCount: Int64
}

struct ASHRuntimeToolchainV4: Codable, Equatable, Hashable, Sendable {
    let swiftCompilerIdentity: String
    let metalCompilerIdentity: String
    let metalLanguageVersion: String
    let sdkBuildIdentity: String
    let deploymentTarget: String
    let targetTriple: String
}

struct ASHRuntimeProvenanceV4: Codable, Equatable, Hashable, Sendable {
    let sourceRevision: String
    let builderID: String
    let builderSourceSHA256: ASHSHA256V4
    let buildParametersSHA256: ASHSHA256V4
    let inputSetSHA256: ASHSHA256V4
    let metalLibrarySHA256: ASHSHA256V4
    let toolchain: ASHRuntimeToolchainV4

    func validate(releaseStatus: ASHRuntimeReleaseStatusV4) throws {
        guard Self.isLowercaseHexRevision(sourceRevision),
              Self.isStableText(builderID),
              Self.isStableText(toolchain.swiftCompilerIdentity),
              Self.isStableText(toolchain.metalCompilerIdentity),
              Self.isStableText(toolchain.metalLanguageVersion),
              Self.isStableText(toolchain.sdkBuildIdentity),
              Self.isStableText(toolchain.deploymentTarget),
              Self.isStableText(toolchain.targetTriple) else {
            throw ASHRuntimeManifestV4Error.invalidProvenance(builderID)
        }
        if releaseStatus == .releaseQualified {
            for value in [
                builderID,
                toolchain.swiftCompilerIdentity,
                toolchain.metalCompilerIdentity,
                toolchain.metalLanguageVersion,
                toolchain.sdkBuildIdentity,
                toolchain.deploymentTarget,
                toolchain.targetTriple
            ] where Self.containsForbiddenPreviewIdentity(value) {
                throw ASHRuntimeManifestV4Error.forbiddenPreviewIdentity(value)
            }
        }
    }

    var canonicalSHA256: ASHSHA256V4 {
        get throws {
            try ASHCanonicalJSONV4.hash(
                self,
                domain: "ash-p06-runtime-provenance-v4"
            )
        }
    }

    private static func isLowercaseHexRevision(_ value: String) -> Bool {
        guard value.utf8.count == 40 || value.utf8.count == 64 else {
            return false
        }
        return value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func isStableText(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7f
        }
    }

    private static func containsForbiddenPreviewIdentity(_ value: String) -> Bool {
        let folded = value.lowercased()
        return folded.contains("p05")
            || folded.contains("preview")
            || folded.contains("development")
            || folded.contains("dev-runtime")
    }
}

struct ASHRuntimeManifestV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaID = "ash.p06.runtime-manifest.v1"
    static let runtimeIdentity = "ash-p06-deterministic-v4"
    static let fileName = "runtime-manifest.json"
    static let identityDomain = "ash-p06-runtime-manifest-v4"

    let schemaID: String
    let runtimeID: String
    let releaseStatus: ASHRuntimeReleaseStatusV4
    let provenance: ASHRuntimeProvenanceV4
    let artifacts: [ASHRuntimeArtifactV4]

    init(
        releaseStatus: ASHRuntimeReleaseStatusV4,
        provenance: ASHRuntimeProvenanceV4,
        artifacts: [ASHRuntimeArtifactV4]
    ) throws {
        self.schemaID = Self.currentSchemaID
        self.runtimeID = Self.runtimeIdentity
        self.releaseStatus = releaseStatus
        self.provenance = provenance
        self.artifacts = artifacts
        try validate()
    }

    func validate(
        requiring requiredStatus: ASHRuntimeReleaseStatusV4? = nil
    ) throws {
        guard schemaID == Self.currentSchemaID else {
            throw ASHRuntimeManifestV4Error.unsupportedManifestSchema(schemaID)
        }
        guard runtimeID == Self.runtimeIdentity else {
            throw ASHRuntimeManifestV4Error.invalidRuntimeIdentity(runtimeID)
        }
        if let requiredStatus, releaseStatus != requiredStatus {
            throw ASHRuntimeManifestV4Error.invalidRuntimeIdentity(
                "required status \(requiredStatus.rawValue), observed \(releaseStatus.rawValue)"
            )
        }
        try provenance.validate(releaseStatus: releaseStatus)

        let expectedRoles = Set(ASHRuntimeArtifactRoleV4.allCases)
        let actualRoles = artifacts.map(\.role)
        let actualRoleSet = Set(actualRoles)
        let missing = expectedRoles.subtracting(actualRoleSet).sorted()
        guard missing.isEmpty else {
            throw ASHRuntimeManifestV4Error.incompleteArtifacts(missing: missing)
        }
        let extra = actualRoleSet.subtracting(expectedRoles).sorted()
        guard extra.isEmpty else {
            throw ASHRuntimeManifestV4Error.unexpectedArtifacts(extra: extra)
        }
        for role in actualRoles where actualRoles.filter({ $0 == role }).count > 1 {
            throw ASHRuntimeManifestV4Error.duplicateArtifactRole(role)
        }
        guard actualRoles == actualRoles.sorted() else {
            throw ASHRuntimeManifestV4Error.nonCanonicalArtifactOrdering
        }

        var paths = Set<String>()
        for artifact in artifacts {
            guard paths.insert(artifact.relativePath).inserted else {
                throw ASHRuntimeManifestV4Error.duplicateArtifactPath(
                    artifact.relativePath
                )
            }
            guard artifact.relativePath == artifact.role.canonicalRelativePath,
                  Self.isSafeRelativePath(artifact.relativePath) else {
                throw ASHRuntimeManifestV4Error.invalidArtifactPath(
                    artifact.relativePath
                )
            }
            guard artifact.schemaID == artifact.role.expectedSchemaID else {
                throw ASHRuntimeManifestV4Error.invalidArtifactSchema(
                    role: artifact.role,
                    expected: artifact.role.expectedSchemaID,
                    actual: artifact.schemaID
                )
            }
            guard artifact.byteCount > 0 else {
                throw ASHRuntimeManifestV4Error.invalidArtifactSize(
                    role: artifact.role,
                    byteCount: artifact.byteCount
                )
            }
        }
        guard artifacts.first(where: { $0.role == .metalLibrary })?
            .contentSHA256 == provenance.metalLibrarySHA256 else {
            throw ASHRuntimeManifestV4Error.metalLibraryProvenanceMismatch
        }
    }

    var canonicalSHA256: ASHSHA256V4 {
        get throws {
            try validate()
            return try ASHCanonicalJSONV4.hash(
                self,
                domain: Self.identityDomain
            )
        }
    }

    func artifact(
        for role: ASHRuntimeArtifactRoleV4
    ) -> ASHRuntimeArtifactV4 {
        // validate() guarantees totality and uniqueness.
        artifacts.first(where: { $0.role == role })!
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard path == path.precomposedStringWithCanonicalMapping,
              !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { component in
                !component.isEmpty && component != "." && component != ".."
            }
    }
}
