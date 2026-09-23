import Foundation

// MARK: - Canonical bookmark credentials

enum WorkflowBookmarkCredentialDigestPurposeV4: WorkflowDigestPurpose {}
enum WorkflowBookmarkSetDigestPurposeV4: WorkflowDigestPurpose {}

typealias WorkflowBookmarkCredentialHashV4 =
  WorkflowDigest<WorkflowBookmarkCredentialDigestPurposeV4>
typealias WorkflowBookmarkSetHashV4 =
  WorkflowDigest<WorkflowBookmarkSetDigestPurposeV4>

enum WorkflowScopedResourceRoleV4:
  String,
  CaseIterable,
  Codable,
  Comparable,
  Hashable,
  Sendable
{
  case inputFile = "input_file"
  case outputDirectory = "output_directory"
  case cacheDirectory = "cache_directory"

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

enum WorkflowBookmarkTargetKindV4: String, Codable, Hashable, Sendable {
  case regularFile = "regular_file"
  case directory
}

struct WorkflowBookmarkTargetIdentityV4: Codable, Equatable, Hashable, Sendable {
  let device: UInt64
  let fileID: UInt64
}

private struct WorkflowBookmarkCredentialHashMaterialV4:
  Codable,
  Sendable
{
  let role: WorkflowScopedResourceRoleV4
  let authorizationReference: WorkflowBookmarkReference
  let credentialRevision: UInt64
  let previousCredentialHash: WorkflowBookmarkCredentialHashV4?
  let bookmarkData: Data
  let targetPath: String
  let targetKind: WorkflowBookmarkTargetKindV4
  let targetIdentity: WorkflowBookmarkTargetIdentityV4
}

struct WorkflowBookmarkCredentialV4: Codable, Equatable, Hashable, Sendable {
  static let maximumBookmarkByteCount = 16 * 1_024 * 1_024

  let role: WorkflowScopedResourceRoleV4
  let authorizationReference: WorkflowBookmarkReference
  let credentialRevision: UInt64
  let previousCredentialHash: WorkflowBookmarkCredentialHashV4?
  let bookmarkData: Data
  let targetPath: String
  let targetKind: WorkflowBookmarkTargetKindV4
  let targetIdentity: WorkflowBookmarkTargetIdentityV4
  let credentialHash: WorkflowBookmarkCredentialHashV4

  fileprivate init(
    role: WorkflowScopedResourceRoleV4,
    authorizationReference: WorkflowBookmarkReference,
    credentialRevision: UInt64,
    previousCredentialHash: WorkflowBookmarkCredentialHashV4?,
    bookmarkData: Data,
    targetPath: String,
    targetKind: WorkflowBookmarkTargetKindV4,
    targetIdentity: WorkflowBookmarkTargetIdentityV4,
    credentialHash: WorkflowBookmarkCredentialHashV4
  ) throws {
    guard credentialRevision > 0,
      !bookmarkData.isEmpty,
      bookmarkData.count <= Self.maximumBookmarkByteCount,
      targetPath.utf8.count <= 16_384,
      targetPath.hasPrefix("/")
    else {
      throw WorkflowBookmarkStoreErrorV4.invalidCredential(role)
    }
    let expectedKind: WorkflowBookmarkTargetKindV4 =
      role == .inputFile ? .regularFile : .directory
    guard targetKind == expectedKind else {
      throw WorkflowBookmarkStoreErrorV4.invalidCredential(role)
    }
    if credentialRevision == 1 {
      guard previousCredentialHash == nil else {
        throw WorkflowBookmarkStoreErrorV4.invalidCredential(role)
      }
    } else {
      guard previousCredentialHash != nil else {
        throw WorkflowBookmarkStoreErrorV4.invalidCredential(role)
      }
    }
    self.role = role
    self.authorizationReference = authorizationReference
    self.credentialRevision = credentialRevision
    self.previousCredentialHash = previousCredentialHash
    self.bookmarkData = bookmarkData
    self.targetPath = targetPath
    self.targetKind = targetKind
    self.targetIdentity = targetIdentity
    self.credentialHash = credentialHash
  }

  fileprivate var hashMaterial: WorkflowBookmarkCredentialHashMaterialV4 {
    WorkflowBookmarkCredentialHashMaterialV4(
      role: role,
      authorizationReference: authorizationReference,
      credentialRevision: credentialRevision,
      previousCredentialHash: previousCredentialHash,
      bookmarkData: bookmarkData,
      targetPath: targetPath,
      targetKind: targetKind,
      targetIdentity: targetIdentity
    )
  }
}

struct WorkflowBookmarkSetBodyV4: Codable, Equatable, Hashable, Sendable {
  static let currentSchemaVersion: UInt16 = 2

  let schemaVersion: UInt16
  let generation: UInt64
  let jobBinding: WorkflowJobBinding
  let credentials: [WorkflowBookmarkCredentialV4]

  fileprivate init(
    generation: UInt64,
    jobBinding: WorkflowJobBinding,
    credentials: [WorkflowBookmarkCredentialV4]
  ) throws {
    guard generation > 0,
      credentials.count == WorkflowScopedResourceRoleV4.allCases.count,
      Set(credentials.map(\.role))
        == Set(WorkflowScopedResourceRoleV4.allCases)
    else {
      throw WorkflowBookmarkStoreErrorV4.invalidDocument
    }
    schemaVersion = Self.currentSchemaVersion
    self.generation = generation
    self.jobBinding = jobBinding
    self.credentials = credentials.sorted { $0.role < $1.role }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case generation
    case jobBinding
    case credentials
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
    guard schemaVersion == Self.currentSchemaVersion else {
      throw WorkflowBookmarkStoreErrorV4.unsupportedSchemaVersion(
        schemaVersion
      )
    }
    try self.init(
      generation: container.decode(UInt64.self, forKey: .generation),
      jobBinding: container.decode(
        WorkflowJobBinding.self,
        forKey: .jobBinding
      ),
      credentials: container.decode(
        [WorkflowBookmarkCredentialV4].self,
        forKey: .credentials
      )
    )
  }
}

struct WorkflowBookmarkSetDocumentV4: Codable, Equatable, Hashable, Sendable {
  static let currentSchemaVersion: UInt16 = 2

  let schemaVersion: UInt16
  let bodyHash: WorkflowBookmarkSetHashV4
  let body: WorkflowBookmarkSetBodyV4

  fileprivate init(
    bodyHash: WorkflowBookmarkSetHashV4,
    body: WorkflowBookmarkSetBodyV4
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.bodyHash = bodyHash
    self.body = body
  }
}

/// The only accepted v1 shape. It is decoded canonically, validated against
/// the immutable job binding, sealed as v2, and atomically replaced. No v1
/// credential is ever used before migration succeeds.
struct WorkflowBookmarkSetDocumentV1: Codable, Equatable, Sendable {
  static let schema: UInt16 = 1

  let schemaVersion: UInt16
  let generation: UInt64
  let jobBinding: WorkflowJobBinding
  let credentials: [WorkflowBookmarkCredentialV1]

  init(
    generation: UInt64,
    jobBinding: WorkflowJobBinding,
    credentials: [WorkflowBookmarkCredentialV1]
  ) {
    schemaVersion = Self.schema
    self.generation = generation
    self.jobBinding = jobBinding
    self.credentials = credentials.sorted { $0.role < $1.role }
  }
}

struct WorkflowBookmarkCredentialV1: Codable, Equatable, Sendable {
  let role: WorkflowScopedResourceRoleV4
  let authorizationReference: WorkflowBookmarkReference
  let bookmarkData: Data
  let targetPath: String
  let targetKind: WorkflowBookmarkTargetKindV4
  let targetIdentity: WorkflowBookmarkTargetIdentityV4
}

struct WorkflowBookmarkRegistrationV4: Equatable, Sendable {
  let role: WorkflowScopedResourceRoleV4
  let authorizationReference: WorkflowBookmarkReference
  let url: URL
}

// MARK: - Resolution and active access

struct WorkflowResolvedScopedResourceV4: @unchecked Sendable {
  let url: URL
  let isStale: Bool
  let startAccessing: @Sendable () -> Bool
  let stopAccessing: @Sendable () -> Void

  init(
    url: URL,
    isStale: Bool,
    startAccessing: @escaping @Sendable () -> Bool,
    stopAccessing: @escaping @Sendable () -> Void
  ) {
    self.url = url
    self.isStale = isStale
    self.startAccessing = startAccessing
    self.stopAccessing = stopAccessing
  }
}

protocol WorkflowSecurityScopedBookmarkResolvingV4: Sendable {
  func makeBookmark(
    for url: URL,
    role: WorkflowScopedResourceRoleV4
  ) throws -> Data

  func resolveBookmark(
    _ data: Data,
    role: WorkflowScopedResourceRoleV4
  ) throws -> WorkflowResolvedScopedResourceV4
}

struct WorkflowFoundationSecurityScopedBookmarkResolverV4:
  WorkflowSecurityScopedBookmarkResolvingV4
{
  func makeBookmark(
    for url: URL,
    role: WorkflowScopedResourceRoleV4
  ) throws -> Data {
    // Only the user-selected output directory needs durable sandbox authority.
    // Input snapshots and the cache live inside Mirmir's private container and
    // are independently rebound to their authenticated filesystem identities.
    let options: URL.BookmarkCreationOptions = role == .outputDirectory
      ? [.withSecurityScope]
      : [.withoutImplicitSecurityScope]
    return try url.bookmarkData(
      options: options,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
  }

  func resolveBookmark(
    _ data: Data,
    role: WorkflowScopedResourceRoleV4
  ) throws -> WorkflowResolvedScopedResourceV4 {
    var stale = false
    let usesSecurityScope = role == .outputDirectory
    let options: URL.BookmarkResolutionOptions = usesSecurityScope
      ? [.withSecurityScope, .withoutUI]
      : [.withoutImplicitStartAccessing, .withoutUI]
    let url = try URL(
      resolvingBookmarkData: data,
      options: options,
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
    let startAccessing: @Sendable () -> Bool
    let stopAccessing: @Sendable () -> Void
    if usesSecurityScope {
      startAccessing = { url.startAccessingSecurityScopedResource() }
      stopAccessing = { url.stopAccessingSecurityScopedResource() }
    } else {
      startAccessing = { true }
      stopAccessing = {}
    }
    return WorkflowResolvedScopedResourceV4(
      url: url,
      isStale: stale,
      startAccessing: startAccessing,
      stopAccessing: stopAccessing
    )
  }
}

enum WorkflowBookmarkActivationStatusV4: String, Codable, Sendable {
  case activated
  case refreshed
  case migratedAndActivated = "migrated_and_activated"
  case migratedAndRefreshed = "migrated_and_refreshed"
}

struct WorkflowBookmarkActivationReceiptV4:
  Codable,
  Equatable,
  Sendable
{
  let role: WorkflowScopedResourceRoleV4
  let status: WorkflowBookmarkActivationStatusV4
  let authorizationReference: WorkflowBookmarkReference
  let previousCredentialRevision: UInt64
  let activeCredentialRevision: UInt64
  let activeCredentialHash: WorkflowBookmarkCredentialHashV4
}

enum WorkflowBookmarkActivationFailureReasonV4:
  String,
  Codable,
  Equatable,
  Sendable
{
  case missingRecord = "missing_record"
  case corruptRecord = "corrupt_record"
  case immutableBindingMismatch = "immutable_binding_mismatch"
  case resolutionFailed = "resolution_failed"
  case accessDenied = "access_denied"
  case staleRefreshFailed = "stale_refresh_failed"
  case targetReplaced = "target_replaced"
  case refreshPersistenceFailed = "refresh_persistence_failed"
  case reconciliationFailed = "reconciliation_failed"
}

struct WorkflowBookmarkActivationFailureV4:
  Codable,
  Equatable,
  Sendable
{
  let role: WorkflowScopedResourceRoleV4?
  let reason: WorkflowBookmarkActivationFailureReasonV4
}

enum WorkflowBookmarkActivationResultV4: Sendable {
  case active(WorkflowActivatedBookmarkAccessSetV4)
  case blocked([WorkflowBookmarkActivationFailureV4])
}

enum WorkflowBookmarkStoreErrorV4: Error, Equatable, LocalizedError {
  case unsupportedSchemaVersion(UInt16)
  case invalidCredential(WorkflowScopedResourceRoleV4)
  case invalidDocument
  case corruptDocument
  case missingDocument
  case immutableBindingMismatch
  case duplicateRegistration(WorkflowScopedResourceRoleV4)
  case unexpectedRegistrationSet
  case unsafeTarget(WorkflowScopedResourceRoleV4)
  case targetReplaced(WorkflowScopedResourceRoleV4)
  case accessClosed

  var errorDescription: String? {
    switch self {
    case .unsupportedSchemaVersion(let version):
      "Unsupported bookmark schema version \(version)."
    case .invalidCredential(let role):
      "The \(role.rawValue) bookmark credential is invalid."
    case .invalidDocument:
      "The bookmark set violates its canonical contract."
    case .corruptDocument:
      "The bookmark set is noncanonical or hash-invalid."
    case .missingDocument:
      "The bookmark set is missing."
    case .immutableBindingMismatch:
      "The bookmark set does not match the immutable job binding."
    case .duplicateRegistration(let role):
      "The bookmark role \(role.rawValue) was registered more than once."
    case .unexpectedRegistrationSet:
      "Input, output, and cache bookmarks are all required."
    case .unsafeTarget(let role):
      "The \(role.rawValue) target is not the required filesystem kind."
    case .targetReplaced(let role):
      "The \(role.rawValue) target changed identity after authorization."
    case .accessClosed:
      "The security-scoped access set is already closed."
    }
  }
}

private final class WorkflowScopedResourceLeaseV4: @unchecked Sendable {
  let credential: WorkflowBookmarkCredentialV4
  let url: URL

  private let lock = NSLock()
  private var active = true
  private let stopAccessing: @Sendable () -> Void

  init(
    credential: WorkflowBookmarkCredentialV4,
    resolved: WorkflowResolvedScopedResourceV4
  ) {
    self.credential = credential
    url = resolved.url.standardizedFileURL
    stopAccessing = resolved.stopAccessing
  }

  func validate() throws {
    let isActive = lock.withLock { active }
    guard isActive else { throw WorkflowBookmarkStoreErrorV4.accessClosed }
    try WorkflowSecurityScopedBookmarkStoreV4.validateTarget(
      url,
      credential: credential
    )
  }

  func close() {
    let shouldStop = lock.withLock {
      guard active else { return false }
      active = false
      return true
    }
    if shouldStop { stopAccessing() }
  }

  deinit {
    close()
  }
}

final class WorkflowActivatedBookmarkAccessSetV4: @unchecked Sendable {
  let document: WorkflowBookmarkSetDocumentV4
  let receipts: [WorkflowBookmarkActivationReceiptV4]

  private let lock = NSLock()
  private var leases: [WorkflowScopedResourceRoleV4: WorkflowScopedResourceLeaseV4]

  fileprivate init(
    document: WorkflowBookmarkSetDocumentV4,
    receipts: [WorkflowBookmarkActivationReceiptV4],
    leases: [WorkflowScopedResourceRoleV4: WorkflowScopedResourceLeaseV4]
  ) {
    self.document = document
    self.receipts = receipts.sorted { $0.role < $1.role }
    self.leases = leases
  }

  func url(for role: WorkflowScopedResourceRoleV4) throws -> URL {
    guard let lease = lock.withLock({ leases[role] }) else {
      throw WorkflowBookmarkStoreErrorV4.accessClosed
    }
    try lease.validate()
    return lease.url
  }

  func revalidateAll() throws {
    let activeLeases = lock.withLock {
      leases.values.sorted { $0.credential.role < $1.credential.role }
    }
    guard activeLeases.count == WorkflowScopedResourceRoleV4.allCases.count else {
      throw WorkflowBookmarkStoreErrorV4.accessClosed
    }
    for lease in activeLeases { try lease.validate() }
  }

  func activatedOutputScope() throws -> WorkflowActivatedOutputScopeV4 {
    guard
      let credential = document.body.credentials.first(where: {
        $0.role == .outputDirectory
      })
    else {
      throw WorkflowBookmarkStoreErrorV4.invalidDocument
    }
    return try WorkflowActivatedOutputScopeV4(
      bookmark: credential.authorizationReference,
      activatedDirectoryURL: url(for: .outputDirectory)
    )
  }

  func close() {
    let activeLeases = lock.withLock {
      let values = Array(leases.values)
      leases.removeAll(keepingCapacity: false)
      return values
    }
    for lease in activeLeases { lease.close() }
  }

  deinit {
    close()
  }
}

// MARK: - Durable store

actor WorkflowSecurityScopedBookmarkStoreV4 {
  private static let documentName = "access-v2.json"
  private static let maximumDocumentByteCount =
    3 * WorkflowBookmarkCredentialV4.maximumBookmarkByteCount + 128 * 1_024

  let rootURL: URL

  private let fileSystem: any WorkflowDurableFileSystem
  private let codec = WorkflowCanonicalCodec()

  init(
    rootURL: URL,
    fileSystem: (any WorkflowDurableFileSystem)? = nil
  ) throws {
    let standardized = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    self.rootURL = standardized
    self.fileSystem =
      try fileSystem
      ?? WorkflowLocalDurableFileSystem(trustedRootURL: standardized)
  }

  @discardableResult
  func register(
    specification: WorkflowJobSpecification,
    registrations: [WorkflowBookmarkRegistrationV4],
    resolver: any WorkflowSecurityScopedBookmarkResolvingV4 =
      WorkflowFoundationSecurityScopedBookmarkResolverV4()
  ) throws -> WorkflowBookmarkSetDocumentV4 {
    let registrationMap = try Self.validateRegistrations(
      registrations,
      specification: specification
    )
    let directory = bookmarkDirectoryURL(for: specification.jobID)
    try fileSystem.ensureDirectory(directory)
    return try fileSystem.withExclusiveLock(
      at: bookmarkLockURL(for: specification.jobID)
    ) { transaction in
      let credentials = try WorkflowScopedResourceRoleV4.allCases.map { role in
        guard let registration = registrationMap[role] else {
          throw WorkflowBookmarkStoreErrorV4.unexpectedRegistrationSet
        }
        let target = try Self.captureTarget(registration.url, role: role)
        let bookmarkData = try resolver.makeBookmark(
          for: registration.url,
          role: role
        )
        return try makeCredential(
          role: role,
          authorizationReference: registration.authorizationReference,
          credentialRevision: 1,
          previousCredentialHash: nil,
          bookmarkData: bookmarkData,
          targetPath: target.path,
          targetKind: target.kind,
          targetIdentity: target.identity
        )
      }
      let body = try WorkflowBookmarkSetBodyV4(
        generation: 1,
        jobBinding: specification.binding,
        credentials: credentials
      )
      let document = try makeDocument(body: body)
      let url = bookmarkDocumentURL(for: specification.jobID)
      let data = try canonicalData(document)
      if try transaction.regularFileExists(url) {
        let existing = try loadVerified(
          specification: specification,
          transaction: transaction,
          migrateLegacy: false
        ).document
        guard existing == document else {
          throw WorkflowBookmarkStoreErrorV4.invalidDocument
        }
        return existing
      }
      try transaction.writeNewAtomically(data, to: url)
      return document
    }
  }

  func load(
    specification: WorkflowJobSpecification
  ) throws -> WorkflowBookmarkSetDocumentV4 {
    let directory = bookmarkDirectoryURL(for: specification.jobID)
    try fileSystem.ensureDirectory(directory)
    return try fileSystem.withExclusiveLock(
      at: bookmarkLockURL(for: specification.jobID)
    ) { transaction in
      try loadVerified(
        specification: specification,
        transaction: transaction,
        migrateLegacy: true
      ).document
    }
  }

  func activate(
    specification: WorkflowJobSpecification,
    resolver: any WorkflowSecurityScopedBookmarkResolvingV4 =
      WorkflowFoundationSecurityScopedBookmarkResolverV4()
  ) -> WorkflowBookmarkActivationResultV4 {
    let directory = bookmarkDirectoryURL(for: specification.jobID)
    do {
      try fileSystem.ensureDirectory(directory)
    } catch {
      return .blocked([
        WorkflowBookmarkActivationFailureV4(
          role: nil,
          reason: .corruptRecord
        )
      ])
    }

    do {
      return try fileSystem.withExclusiveLock(
        at: bookmarkLockURL(for: specification.jobID)
      ) { transaction in
        let loaded: LoadedDocument
        do {
          loaded = try loadVerified(
            specification: specification,
            transaction: transaction,
            migrateLegacy: true
          )
        } catch WorkflowBookmarkStoreErrorV4.missingDocument {
          return .blocked([
            WorkflowBookmarkActivationFailureV4(
              role: nil,
              reason: .missingRecord
            )
          ])
        } catch WorkflowBookmarkStoreErrorV4.immutableBindingMismatch {
          return .blocked([
            WorkflowBookmarkActivationFailureV4(
              role: nil,
              reason: .immutableBindingMismatch
            )
          ])
        } catch {
          return .blocked([
            WorkflowBookmarkActivationFailureV4(
              role: nil,
              reason: .corruptRecord
            )
          ])
        }
        return try activateLocked(
          loaded: loaded,
          specification: specification,
          resolver: resolver,
          transaction: transaction
        )
      }
    } catch {
      return .blocked([
        WorkflowBookmarkActivationFailureV4(
          role: nil,
          reason: .refreshPersistenceFailed
        )
      ])
    }
  }
}

extension WorkflowSecurityScopedBookmarkStoreV4 {
  fileprivate struct TargetCapture {
    let path: String
    let kind: WorkflowBookmarkTargetKindV4
    let identity: WorkflowBookmarkTargetIdentityV4
  }

  fileprivate struct SchemaProbe: Decodable {
    let schemaVersion: UInt16
  }

  fileprivate struct LoadedDocument {
    let document: WorkflowBookmarkSetDocumentV4
    let migrated: Bool
  }

  fileprivate func activateLocked(
    loaded: LoadedDocument,
    specification: WorkflowJobSpecification,
    resolver: any WorkflowSecurityScopedBookmarkResolvingV4,
    transaction: any WorkflowDurableFileSystem
  ) throws -> WorkflowBookmarkActivationResultV4 {
    var leases: [WorkflowScopedResourceRoleV4: WorkflowScopedResourceLeaseV4] = [:]
    var activeCredentials: [WorkflowBookmarkCredentialV4] = []
    var refreshedRoles: Set<WorkflowScopedResourceRoleV4> = []

    func closeLeases() {
      for lease in leases.values { lease.close() }
      leases.removeAll(keepingCapacity: false)
    }

    for credential in loaded.document.body.credentials {
      let resolved: WorkflowResolvedScopedResourceV4
      do {
        resolved = try resolver.resolveBookmark(
          credential.bookmarkData,
          role: credential.role
        )
      } catch {
        closeLeases()
        return .blocked([
          WorkflowBookmarkActivationFailureV4(
            role: credential.role,
            reason: .resolutionFailed
          )
        ])
      }
      guard resolved.startAccessing() else {
        closeLeases()
        return .blocked([
          WorkflowBookmarkActivationFailureV4(
            role: credential.role,
            reason: .accessDenied
          )
        ])
      }
      let lease = WorkflowScopedResourceLeaseV4(
        credential: credential,
        resolved: resolved
      )
      do {
        try lease.validate()
      } catch {
        lease.close()
        closeLeases()
        return .blocked([
          WorkflowBookmarkActivationFailureV4(
            role: credential.role,
            reason: .targetReplaced
          )
        ])
      }
      leases[credential.role] = lease

      guard resolved.isStale else {
        activeCredentials.append(credential)
        continue
      }
      let refreshedData: Data
      do {
        refreshedData = try resolver.makeBookmark(
          for: lease.url,
          role: credential.role
        )
      } catch {
        closeLeases()
        return .blocked([
          WorkflowBookmarkActivationFailureV4(
            role: credential.role,
            reason: .staleRefreshFailed
          )
        ])
      }
      guard credential.credentialRevision < UInt64.max else {
        closeLeases()
        return .blocked([
          WorkflowBookmarkActivationFailureV4(
            role: credential.role,
            reason: .staleRefreshFailed
          )
        ])
      }
      activeCredentials.append(
        try makeCredential(
          role: credential.role,
          authorizationReference: credential.authorizationReference,
          credentialRevision: credential.credentialRevision + 1,
          previousCredentialHash: credential.credentialHash,
          bookmarkData: refreshedData,
          targetPath: credential.targetPath,
          targetKind: credential.targetKind,
          targetIdentity: credential.targetIdentity
        )
      )
      refreshedRoles.insert(credential.role)
    }

    var activeDocument = loaded.document
    if !refreshedRoles.isEmpty {
      guard loaded.document.body.generation < UInt64.max else {
        closeLeases()
        return .blocked([
          WorkflowBookmarkActivationFailureV4(
            role: nil,
            reason: .refreshPersistenceFailed
          )
        ])
      }
      do {
        let body = try WorkflowBookmarkSetBodyV4(
          generation: loaded.document.body.generation + 1,
          jobBinding: specification.binding,
          credentials: activeCredentials
        )
        activeDocument = try makeDocument(body: body)
        try transaction.replaceAtomically(
          canonicalData(activeDocument),
          at: bookmarkDocumentURL(for: specification.jobID)
        )
      } catch {
        closeLeases()
        return .blocked([
          WorkflowBookmarkActivationFailureV4(
            role: nil,
            reason: .refreshPersistenceFailed
          )
        ])
      }
    }

    // Credentials in a refreshed document differ from the credentials
    // retained by the leases only in bookmark bytes and hash-chain fields;
    // target authority is immutable. Build final leases with the refreshed
    // credential values so all later validations are document-bound.
    if !refreshedRoles.isEmpty {
      for credential in activeDocument.body.credentials {
        guard let oldLease = leases[credential.role] else {
          closeLeases()
          throw WorkflowBookmarkStoreErrorV4.invalidDocument
        }
        leases[credential.role] = WorkflowScopedResourceLeaseV4(
          credential: credential,
          resolved: WorkflowResolvedScopedResourceV4(
            url: oldLease.url,
            isStale: false,
            startAccessing: { true },
            stopAccessing: { oldLease.close() }
          )
        )
      }
    }

    var receipts: [WorkflowBookmarkActivationReceiptV4] = []
    for credential in activeDocument.body.credentials {
      guard
        let previous = loaded.document.body.credentials.first(where: {
          $0.role == credential.role
        })
      else {
        closeLeases()
        throw WorkflowBookmarkStoreErrorV4.invalidDocument
      }
      let refreshed = refreshedRoles.contains(credential.role)
      let status: WorkflowBookmarkActivationStatusV4
      switch (loaded.migrated, refreshed) {
      case (false, false): status = .activated
      case (false, true): status = .refreshed
      case (true, false): status = .migratedAndActivated
      case (true, true): status = .migratedAndRefreshed
      }
      receipts.append(
        WorkflowBookmarkActivationReceiptV4(
          role: credential.role,
          status: status,
          authorizationReference: credential.authorizationReference,
          previousCredentialRevision: previous.credentialRevision,
          activeCredentialRevision: credential.credentialRevision,
          activeCredentialHash: credential.credentialHash
        )
      )
    }
    let set = WorkflowActivatedBookmarkAccessSetV4(
      document: activeDocument,
      receipts: receipts,
      leases: leases
    )
    do {
      try set.revalidateAll()
    } catch {
      set.close()
      return .blocked([
        WorkflowBookmarkActivationFailureV4(
          role: nil,
          reason: .targetReplaced
        )
      ])
    }
    return .active(set)
  }

  fileprivate func loadVerified(
    specification: WorkflowJobSpecification,
    transaction: any WorkflowDurableFileSystem,
    migrateLegacy: Bool
  ) throws -> LoadedDocument {
    let url = bookmarkDocumentURL(for: specification.jobID)
    guard try transaction.regularFileExists(url) else {
      throw WorkflowBookmarkStoreErrorV4.missingDocument
    }
    let data = try transaction.readRegularFile(
      url,
      maximumBytes: Self.maximumDocumentByteCount
    )
    let schema: UInt16
    do {
      schema = try JSONDecoder().decode(SchemaProbe.self, from: data)
        .schemaVersion
    } catch {
      throw WorkflowBookmarkStoreErrorV4.corruptDocument
    }
    switch schema {
    case WorkflowBookmarkSetBodyV4.currentSchemaVersion:
      do {
        let document: WorkflowBookmarkSetDocumentV4 =
          try codec.decodeCanonical(
            WorkflowBookmarkSetDocumentV4.self,
            from: data
          )
        try verify(document, specification: specification)
        return LoadedDocument(document: document, migrated: false)
      } catch let error as WorkflowBookmarkStoreErrorV4 {
        throw error
      } catch {
        throw WorkflowBookmarkStoreErrorV4.corruptDocument
      }
    case WorkflowBookmarkSetDocumentV1.schema where migrateLegacy:
      do {
        let legacy: WorkflowBookmarkSetDocumentV1 =
          try codec.decodeCanonical(
            WorkflowBookmarkSetDocumentV1.self,
            from: data
          )
        let migrated = try migrate(
          legacy,
          specification: specification
        )
        try transaction.replaceAtomically(
          canonicalData(migrated),
          at: url
        )
        return LoadedDocument(document: migrated, migrated: true)
      } catch let error as WorkflowBookmarkStoreErrorV4 {
        throw error
      } catch {
        throw WorkflowBookmarkStoreErrorV4.corruptDocument
      }
    default:
      throw WorkflowBookmarkStoreErrorV4.unsupportedSchemaVersion(schema)
    }
  }

  fileprivate func migrate(
    _ legacy: WorkflowBookmarkSetDocumentV1,
    specification: WorkflowJobSpecification
  ) throws -> WorkflowBookmarkSetDocumentV4 {
    guard legacy.schemaVersion == WorkflowBookmarkSetDocumentV1.schema,
      legacy.generation > 0,
      legacy.jobBinding == specification.binding,
      legacy.credentials.count
        == WorkflowScopedResourceRoleV4.allCases.count,
      Set(legacy.credentials.map(\.role))
        == Set(WorkflowScopedResourceRoleV4.allCases)
    else {
      throw WorkflowBookmarkStoreErrorV4.invalidDocument
    }
    let credentials = try legacy.credentials.map { credential in
      try makeCredential(
        role: credential.role,
        authorizationReference: credential.authorizationReference,
        credentialRevision: 1,
        previousCredentialHash: nil,
        bookmarkData: credential.bookmarkData,
        targetPath: credential.targetPath,
        targetKind: credential.targetKind,
        targetIdentity: credential.targetIdentity
      )
    }
    let body = try WorkflowBookmarkSetBodyV4(
      generation: legacy.generation,
      jobBinding: legacy.jobBinding,
      credentials: credentials
    )
    let document = try makeDocument(body: body)
    try verify(document, specification: specification)
    return document
  }

  fileprivate func makeCredential(
    role: WorkflowScopedResourceRoleV4,
    authorizationReference: WorkflowBookmarkReference,
    credentialRevision: UInt64,
    previousCredentialHash: WorkflowBookmarkCredentialHashV4?,
    bookmarkData: Data,
    targetPath: String,
    targetKind: WorkflowBookmarkTargetKindV4,
    targetIdentity: WorkflowBookmarkTargetIdentityV4
  ) throws -> WorkflowBookmarkCredentialV4 {
    let placeholder = try WorkflowBookmarkCredentialV4(
      role: role,
      authorizationReference: authorizationReference,
      credentialRevision: credentialRevision,
      previousCredentialHash: previousCredentialHash,
      bookmarkData: bookmarkData,
      targetPath: targetPath,
      targetKind: targetKind,
      targetIdentity: targetIdentity,
      credentialHash: WorkflowBookmarkCredentialHashV4(
        String(repeating: "0", count: 64)
      )
    )
    let material = try codec.canonicalData(placeholder.hashMaterial)
    let hash = try WorkflowBookmarkCredentialHashV4(
      WorkflowV4Validation.domainSeparatedSHA256(
        domain: "Mirmir.WorkflowBookmark.Credential.v2\u{0}",
        data: material
      )
    )
    return try WorkflowBookmarkCredentialV4(
      role: role,
      authorizationReference: authorizationReference,
      credentialRevision: credentialRevision,
      previousCredentialHash: previousCredentialHash,
      bookmarkData: bookmarkData,
      targetPath: targetPath,
      targetKind: targetKind,
      targetIdentity: targetIdentity,
      credentialHash: hash
    )
  }

  fileprivate func makeDocument(
    body: WorkflowBookmarkSetBodyV4
  ) throws -> WorkflowBookmarkSetDocumentV4 {
    let hash = try WorkflowBookmarkSetHashV4(
      WorkflowV4Validation.domainSeparatedSHA256(
        domain: "Mirmir.WorkflowBookmark.Set.v2\u{0}",
        data: codec.canonicalData(body)
      )
    )
    return WorkflowBookmarkSetDocumentV4(bodyHash: hash, body: body)
  }

  fileprivate func verify(
    _ document: WorkflowBookmarkSetDocumentV4,
    specification: WorkflowJobSpecification
  ) throws {
    guard document.schemaVersion == WorkflowBookmarkSetDocumentV4.currentSchemaVersion,
      document.body.jobBinding == specification.binding,
      try makeDocument(body: document.body) == document
    else {
      throw WorkflowBookmarkStoreErrorV4.corruptDocument
    }
    for credential in document.body.credentials {
      let rebuilt = try makeCredential(
        role: credential.role,
        authorizationReference: credential.authorizationReference,
        credentialRevision: credential.credentialRevision,
        previousCredentialHash: credential.previousCredentialHash,
        bookmarkData: credential.bookmarkData,
        targetPath: credential.targetPath,
        targetKind: credential.targetKind,
        targetIdentity: credential.targetIdentity
      )
      guard rebuilt == credential else {
        throw WorkflowBookmarkStoreErrorV4.corruptDocument
      }
    }
    let source = document.body.credentials.first { $0.role == .inputFile }
    let output = document.body.credentials.first { $0.role == .outputDirectory }
    guard source?.authorizationReference == specification.source.bookmark,
      output?.authorizationReference
        == specification.output.directoryBookmark
    else {
      throw WorkflowBookmarkStoreErrorV4.immutableBindingMismatch
    }
  }

  fileprivate func canonicalData(_ document: WorkflowBookmarkSetDocumentV4) throws -> Data {
    try verifyDocumentHashes(document)
    return try codec.canonicalData(document)
  }

  fileprivate func verifyDocumentHashes(_ document: WorkflowBookmarkSetDocumentV4) throws {
    guard try makeDocument(body: document.body) == document else {
      throw WorkflowBookmarkStoreErrorV4.corruptDocument
    }
    for credential in document.body.credentials {
      let rebuilt = try makeCredential(
        role: credential.role,
        authorizationReference: credential.authorizationReference,
        credentialRevision: credential.credentialRevision,
        previousCredentialHash: credential.previousCredentialHash,
        bookmarkData: credential.bookmarkData,
        targetPath: credential.targetPath,
        targetKind: credential.targetKind,
        targetIdentity: credential.targetIdentity
      )
      guard rebuilt == credential else {
        throw WorkflowBookmarkStoreErrorV4.corruptDocument
      }
    }
  }

  fileprivate func bookmarkDirectoryURL(for jobID: WorkflowJobID) -> URL {
    rootURL
      .appendingPathComponent("jobs", isDirectory: true)
      .appendingPathComponent(jobID.rawValue, isDirectory: true)
      .appendingPathComponent("bookmarks-v4", isDirectory: true)
  }

  fileprivate func bookmarkDocumentURL(for jobID: WorkflowJobID) -> URL {
    bookmarkDirectoryURL(for: jobID).appendingPathComponent(Self.documentName)
  }

  fileprivate func bookmarkLockURL(for jobID: WorkflowJobID) -> URL {
    bookmarkDirectoryURL(for: jobID).appendingPathComponent("access.lock")
  }

  fileprivate static func validateRegistrations(
    _ registrations: [WorkflowBookmarkRegistrationV4],
    specification: WorkflowJobSpecification
  ) throws -> [WorkflowScopedResourceRoleV4: WorkflowBookmarkRegistrationV4] {
    guard registrations.count == WorkflowScopedResourceRoleV4.allCases.count else {
      throw WorkflowBookmarkStoreErrorV4.unexpectedRegistrationSet
    }
    var result: [WorkflowScopedResourceRoleV4: WorkflowBookmarkRegistrationV4] = [:]
    for registration in registrations {
      guard result.updateValue(registration, forKey: registration.role) == nil else {
        throw WorkflowBookmarkStoreErrorV4.duplicateRegistration(
          registration.role
        )
      }
    }
    guard
      result[.inputFile]?.authorizationReference
        == specification.source.bookmark,
      result[.outputDirectory]?.authorizationReference
        == specification.output.directoryBookmark
    else {
      throw WorkflowBookmarkStoreErrorV4.immutableBindingMismatch
    }
    return result
  }

  fileprivate static func captureTarget(
    _ url: URL,
    role: WorkflowScopedResourceRoleV4
  ) throws -> TargetCapture {
    let standardized = url.standardizedFileURL
    var metadata = stat()
    guard standardized.isFileURL,
      lstat(standardized.path, &metadata) == 0
    else {
      throw WorkflowBookmarkStoreErrorV4.unsafeTarget(role)
    }
    let kind: WorkflowBookmarkTargetKindV4
    switch role {
    case .inputFile:
      guard (metadata.st_mode & S_IFMT) == S_IFREG,
        metadata.st_nlink == 1
      else {
        throw WorkflowBookmarkStoreErrorV4.unsafeTarget(role)
      }
      kind = .regularFile
    case .outputDirectory, .cacheDirectory:
      guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
        throw WorkflowBookmarkStoreErrorV4.unsafeTarget(role)
      }
      kind = .directory
    }
    return TargetCapture(
      path: standardized.path,
      kind: kind,
      identity: WorkflowBookmarkTargetIdentityV4(
        device: UInt64(metadata.st_dev),
        fileID: UInt64(metadata.st_ino)
      )
    )
  }

  fileprivate static func validateTarget(
    _ url: URL,
    credential: WorkflowBookmarkCredentialV4
  ) throws {
    let captured = try captureTarget(url, role: credential.role)
    guard captured.path == credential.targetPath,
      captured.kind == credential.targetKind,
      captured.identity == credential.targetIdentity
    else {
      throw WorkflowBookmarkStoreErrorV4.targetReplaced(credential.role)
    }
  }
}
