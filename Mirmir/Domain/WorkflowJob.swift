import Foundation

enum WorkflowDomainValidationError: Error, Equatable, LocalizedError {
    case invalidIdentifier(String)
    case invalidSHA256Digest(String)
    case invalidOutputFileName(String)
    case invalidBookmarkRevision(UInt64)
    case unsupportedSchemaVersion(type: String, actual: UInt16, current: UInt16)
    case invalidEventEnvelope(String)
    case invalidSnapshot(String)

    var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(value):
            "Invalid workflow identifier: \(value)"
        case let .invalidSHA256Digest(value):
            "Invalid lowercase SHA-256 digest: \(value)"
        case let .invalidOutputFileName(value):
            "Invalid output file name: \(value)"
        case let .invalidBookmarkRevision(revision):
            "Bookmark revisions must be positive; received \(revision)."
        case let .unsupportedSchemaVersion(type, actual, current):
            "Unsupported \(type) schema version \(actual); current version is \(current)."
        case let .invalidEventEnvelope(reason):
            "Invalid workflow event envelope: \(reason)"
        case let .invalidSnapshot(reason):
            "Invalid workflow snapshot: \(reason)"
        }
    }
}

protocol WorkflowIdentifierPurpose: Sendable {}

struct WorkflowIdentifier<Purpose: WorkflowIdentifierPurpose>:
    Codable,
    Comparable,
    CustomStringConvertible,
    Hashable,
    Sendable
{
    let rawValue: String

    init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw WorkflowDomainValidationError.invalidIdentifier(rawValue)
        }
        self.rawValue = rawValue
    }

    var description: String {
        rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard
            !scalars.isEmpty,
            scalars.count <= 128,
            let first = scalars.first,
            isASCIILetterOrDigit(first)
        else {
            return false
        }

        return scalars.allSatisfy { scalar in
            isASCIILetterOrDigit(scalar)
                || scalar == "-"
                || scalar == "_"
                || scalar == "."
                || scalar == ":"
        }
    }
}

protocol WorkflowDigestPurpose: Sendable {}

struct WorkflowDigest<Purpose: WorkflowDigestPurpose>:
    Codable,
    Comparable,
    CustomStringConvertible,
    Hashable,
    Sendable
{
    let rawValue: String

    init(_ rawValue: String) throws {
        guard Self.isLowercaseSHA256(rawValue) else {
            throw WorkflowDomainValidationError.invalidSHA256Digest(rawValue)
        }
        self.rawValue = rawValue
    }

    var description: String {
        rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard scalars.count == 64 else {
            return false
        }
        return scalars.allSatisfy { scalar in
            switch scalar.value {
            case 48 ... 57, 97 ... 102:
                true
            default:
                false
            }
        }
    }
}

enum WorkflowJobIDPurpose: WorkflowIdentifierPurpose {}
enum WorkflowAttemptIDPurpose: WorkflowIdentifierPurpose {}
enum WorkflowEventIDPurpose: WorkflowIdentifierPurpose {}
enum WorkflowCommandIDPurpose: WorkflowIdentifierPurpose {}
enum WorkflowBookmarkIDPurpose: WorkflowIdentifierPurpose {}
enum WorkflowBackendIDPurpose: WorkflowIdentifierPurpose {}
enum WorkflowBackendRevisionIDPurpose: WorkflowIdentifierPurpose {}

typealias WorkflowJobID = WorkflowIdentifier<WorkflowJobIDPurpose>
typealias WorkflowAttemptID = WorkflowIdentifier<WorkflowAttemptIDPurpose>
typealias WorkflowEventID = WorkflowIdentifier<WorkflowEventIDPurpose>
typealias WorkflowCommandID = WorkflowIdentifier<WorkflowCommandIDPurpose>
typealias WorkflowBookmarkID = WorkflowIdentifier<WorkflowBookmarkIDPurpose>
typealias WorkflowBackendID = WorkflowIdentifier<WorkflowBackendIDPurpose>
typealias WorkflowBackendRevisionID =
    WorkflowIdentifier<WorkflowBackendRevisionIDPurpose>

enum WorkflowRequestDigestPurpose: WorkflowDigestPurpose {}
enum WorkflowPlanDigestPurpose: WorkflowDigestPurpose {}
enum WorkflowRuntimeManifestDigestPurpose: WorkflowDigestPurpose {}
enum WorkflowRuntimeBindingDigestPurpose: WorkflowDigestPurpose {}
enum WorkflowSourceIdentityDigestPurpose: WorkflowDigestPurpose {}
enum WorkflowOutputContractDigestPurpose: WorkflowDigestPurpose {}
enum WorkflowMediaContractDigestPurpose: WorkflowDigestPurpose {}
enum WorkflowBookmarkDocumentDigestPurpose: WorkflowDigestPurpose {}
enum WorkflowPayloadDigestPurpose: WorkflowDigestPurpose {}
enum WorkflowEventDigestPurpose: WorkflowDigestPurpose {}

typealias WorkflowRequestID = WorkflowDigest<WorkflowRequestDigestPurpose>
typealias WorkflowPlanID = WorkflowDigest<WorkflowPlanDigestPurpose>
typealias WorkflowRuntimeManifestID =
    WorkflowDigest<WorkflowRuntimeManifestDigestPurpose>
typealias WorkflowRuntimeBindingID =
    WorkflowDigest<WorkflowRuntimeBindingDigestPurpose>
typealias WorkflowSourceIdentityID =
    WorkflowDigest<WorkflowSourceIdentityDigestPurpose>
typealias WorkflowOutputContractID =
    WorkflowDigest<WorkflowOutputContractDigestPurpose>
typealias WorkflowMediaContractID =
    WorkflowDigest<WorkflowMediaContractDigestPurpose>
typealias WorkflowBookmarkDocumentHash =
    WorkflowDigest<WorkflowBookmarkDocumentDigestPurpose>
typealias WorkflowPayloadHash = WorkflowDigest<WorkflowPayloadDigestPurpose>
typealias WorkflowEventHash = WorkflowDigest<WorkflowEventDigestPurpose>

struct WorkflowOutputFileName:
    Codable,
    CustomStringConvertible,
    Hashable,
    Sendable
{
    let rawValue: String

    init(_ rawValue: String) throws {
        guard
            !rawValue.isEmpty,
            rawValue != ".",
            rawValue != "..",
            rawValue.utf8.count <= 255,
            !rawValue.contains("/"),
            !rawValue.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw WorkflowDomainValidationError.invalidOutputFileName(rawValue)
        }
        self.rawValue = rawValue
    }

    var description: String {
        rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct WorkflowBookmarkReference: Codable, Hashable, Sendable {
    let bookmarkID: WorkflowBookmarkID
    let revision: UInt64
    let documentHash: WorkflowBookmarkDocumentHash

    init(
        bookmarkID: WorkflowBookmarkID,
        revision: UInt64,
        documentHash: WorkflowBookmarkDocumentHash
    ) throws {
        guard revision > 0 else {
            throw WorkflowDomainValidationError.invalidBookmarkRevision(revision)
        }
        self.bookmarkID = bookmarkID
        self.revision = revision
        self.documentHash = documentHash
    }

    private enum CodingKeys: String, CodingKey {
        case bookmarkID
        case revision
        case documentHash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            bookmarkID: container.decode(
                WorkflowBookmarkID.self,
                forKey: .bookmarkID
            ),
            revision: container.decode(UInt64.self, forKey: .revision),
            documentHash: container.decode(
                WorkflowBookmarkDocumentHash.self,
                forKey: .documentHash
            )
        )
    }
}

struct WorkflowSourceSpecification: Codable, Hashable, Sendable {
    let identityID: WorkflowSourceIdentityID
    let bookmark: WorkflowBookmarkReference
}

struct WorkflowOutputSpecification: Codable, Hashable, Sendable {
    let contractID: WorkflowOutputContractID
    let directoryBookmark: WorkflowBookmarkReference
    let fileName: WorkflowOutputFileName
}

struct WorkflowRuntimeBinding: Codable, Hashable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let id: WorkflowRuntimeBindingID
    let runtimeManifestID: WorkflowRuntimeManifestID
    let planID: WorkflowPlanID
    let backendID: WorkflowBackendID
    let backendRevisionID: WorkflowBackendRevisionID
    let mediaContractID: WorkflowMediaContractID

    init(
        id: WorkflowRuntimeBindingID,
        runtimeManifestID: WorkflowRuntimeManifestID,
        planID: WorkflowPlanID,
        backendID: WorkflowBackendID,
        backendRevisionID: WorkflowBackendRevisionID,
        mediaContractID: WorkflowMediaContractID
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.runtimeManifestID = runtimeManifestID
        self.planID = planID
        self.backendID = backendID
        self.backendRevisionID = backendRevisionID
        self.mediaContractID = mediaContractID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case runtimeManifestID
        case planID
        case backendID
        case backendRevisionID
        case mediaContractID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WorkflowDomainValidationError.unsupportedSchemaVersion(
                type: "WorkflowRuntimeBinding",
                actual: schemaVersion,
                current: Self.currentSchemaVersion
            )
        }

        self.init(
            id: try container.decode(
                WorkflowRuntimeBindingID.self,
                forKey: .id
            ),
            runtimeManifestID: try container.decode(
                WorkflowRuntimeManifestID.self,
                forKey: .runtimeManifestID
            ),
            planID: try container.decode(
                WorkflowPlanID.self,
                forKey: .planID
            ),
            backendID: try container.decode(
                WorkflowBackendID.self,
                forKey: .backendID
            ),
            backendRevisionID: try container.decode(
                WorkflowBackendRevisionID.self,
                forKey: .backendRevisionID
            ),
            mediaContractID: try container.decode(
                WorkflowMediaContractID.self,
                forKey: .mediaContractID
            )
        )
    }
}

struct WorkflowJobBinding: Codable, Hashable, Sendable {
    let jobID: WorkflowJobID
    let requestID: WorkflowRequestID
    let sourceIdentityID: WorkflowSourceIdentityID
    let outputContractID: WorkflowOutputContractID
    let planID: WorkflowPlanID
    let runtimeBindingID: WorkflowRuntimeBindingID
}

struct WorkflowJobSpecification: Codable, Hashable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let jobID: WorkflowJobID
    let requestID: WorkflowRequestID
    let source: WorkflowSourceSpecification
    let output: WorkflowOutputSpecification
    let runtimeBinding: WorkflowRuntimeBinding

    init(
        jobID: WorkflowJobID,
        requestID: WorkflowRequestID,
        source: WorkflowSourceSpecification,
        output: WorkflowOutputSpecification,
        runtimeBinding: WorkflowRuntimeBinding
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.jobID = jobID
        self.requestID = requestID
        self.source = source
        self.output = output
        self.runtimeBinding = runtimeBinding
    }

    var binding: WorkflowJobBinding {
        WorkflowJobBinding(
            jobID: jobID,
            requestID: requestID,
            sourceIdentityID: source.identityID,
            outputContractID: output.contractID,
            planID: runtimeBinding.planID,
            runtimeBindingID: runtimeBinding.id
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case jobID
        case requestID
        case source
        case output
        case runtimeBinding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WorkflowDomainValidationError.unsupportedSchemaVersion(
                type: "WorkflowJobSpecification",
                actual: schemaVersion,
                current: Self.currentSchemaVersion
            )
        }

        self.init(
            jobID: try container.decode(
                WorkflowJobID.self,
                forKey: .jobID
            ),
            requestID: try container.decode(
                WorkflowRequestID.self,
                forKey: .requestID
            ),
            source: try container.decode(
                WorkflowSourceSpecification.self,
                forKey: .source
            ),
            output: try container.decode(
                WorkflowOutputSpecification.self,
                forKey: .output
            ),
            runtimeBinding: try container.decode(
                WorkflowRuntimeBinding.self,
                forKey: .runtimeBinding
            )
        )
    }
}

private func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 48 ... 57, 65 ... 90, 97 ... 122:
        true
    default:
        false
    }
}
