import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import Metal
import SwiftUI

@main
@MainActor
struct MirmirApp: App {
    @NSApplicationDelegateAdaptor(MirmirApplicationDelegate.self)
    private var applicationDelegate
    @State private var viewModel: MirmirViewModel?

    init() {
        // Qualification is an isolated process mode. In particular, it must
        // not instantiate the normal UI composition, whose production queue
        // belongs to the user rather than the release observer.
        _viewModel = State(initialValue:
            MirmirNotarizedSmokeInvocationV4.wasRequested
                || MirmirPackagedEvidenceInvocationV4.wasRequested
                ? nil
                : MirmirViewModel()
        )
    }

    var body: some Scene {
        WindowGroup("Mirmir", id: "main") {
            if let viewModel {
                RootView(viewModel: viewModel)
                    .frame(minWidth: 960, minHeight: 680)
            } else {
                EmptyView()
            }
        }
        .defaultSize(width: 1_180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") {
                    viewModel?.openVideo()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(viewModel?.isProcessing ?? true)
            }
        }
    }
}

// MARK: - Exact packaged-candidate quality and parity observer

/// A release lane may score pixels only when they were emitted by the exact
/// executable carried by the attested application archive. This command
/// envelope is deliberately part of the shipping target: neither XCTest nor
/// an ENABLE_TESTABILITY rebuild participates in the normative capture.
private enum MirmirPackagedEvidenceInvocationV4 {
    static let flag = "--mirmir-v4-packaged-evidence"
    static let resultPrefix = "MIRMIR_V4_PACKAGED_EVIDENCE_RESULT "
    static let errorPrefix = "MIRMIR_V4_PACKAGED_EVIDENCE_ERROR "

    static var wasRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.count == 3 && arguments[1] == flag
    }

    static func parse() throws -> (
        request: MirmirPackagedEvidenceRequestV4,
        canonicalData: Data
    ) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.count == 3,
              arguments[1] == flag,
              let bytes = Data(base64Encoded: arguments[2]),
              !bytes.isEmpty else {
            throw MirmirPackagedEvidenceErrorV4.invalidInvocation
        }
        let request: MirmirPackagedEvidenceRequestV4
        do {
            request = try JSONDecoder().decode(
                MirmirPackagedEvidenceRequestV4.self,
                from: bytes
            )
        } catch {
            throw MirmirPackagedEvidenceErrorV4.invalidRequest(
                "the command envelope is not request JSON"
            )
        }
        let canonical = try MirmirNotarizedSmokeFilesV4.canonicalData(request)
        guard canonical == bytes else {
            throw MirmirPackagedEvidenceErrorV4.invalidRequest(
                "the command envelope contains unknown, duplicate, or noncanonical fields"
            )
        }
        try request.validate()
        return (request, canonical)
    }
}

private enum MirmirPackagedEvidenceLaneV4: String, Codable, Sendable {
    case quality
    case parity
    case performance
    case media
    case recovery
}

private struct MirmirPackagedCodeDirectoryV4:
    Codable, Equatable, Sendable {
    let architecture: String
    let sha256: String
}

private struct MirmirPackagedCandidateIdentityV4:
    Codable, Equatable, Sendable {
    static let schema = "mirmir-v4-packaged-candidate-identity-v1"

    let schemaVersion: String
    let buildConfiguration: String
    let applicationArchiveSHA256: String
    let applicationPayloadIdentitySHA256: String
    let applicationInfoPlistSHA256: String
    let applicationExecutableSHA256: String
    let codeDirectories: [MirmirPackagedCodeDirectoryV4]
    let codeDirectorySetSHA256: String
    let designatedRequirementSHA256: String
    let releaseConfigurationSHA256: String
    let attestationSHA256: String
    let sourceCommit: String
    let sourceTreeIdentitySHA256: String
    let runtimeManifestSHA256: String
    let runtimeManifestFileSHA256: String
    let runtimeArtifactSetSHA256: String
    let runtimeSourceRevision: String
    let bundleIdentifier: String
    let productVersion: String
    let productBuild: String

    func validate() throws {
        guard schemaVersion == Self.schema,
              buildConfiguration == "Release",
              !codeDirectories.isEmpty,
              codeDirectories == codeDirectories.sorted(by: {
                  $0.architecture < $1.architecture
              }),
              Set(codeDirectories.map(\.architecture)).count
                == codeDirectories.count else {
            throw MirmirPackagedEvidenceErrorV4.invalidRequest(
                "packaged candidate header or architecture set differs"
            )
        }
        for value in [
            applicationArchiveSHA256,
            applicationPayloadIdentitySHA256,
            applicationInfoPlistSHA256,
            applicationExecutableSHA256,
            codeDirectorySetSHA256,
            designatedRequirementSHA256,
            releaseConfigurationSHA256,
            attestationSHA256,
            sourceTreeIdentitySHA256,
            runtimeManifestSHA256,
            runtimeManifestFileSHA256,
            runtimeArtifactSetSHA256
        ] {
            try requireHex(value, lengths: [64], label: "candidate identity")
        }
        try requireHex(sourceCommit, lengths: [40], label: "sourceCommit")
        try requireHex(
            runtimeSourceRevision,
            lengths: [40, 64],
            label: "runtimeSourceRevision"
        )
        for row in codeDirectories {
            guard row.architecture.range(
                of: "^[A-Za-z0-9_]+$",
                options: .regularExpression
            ) != nil else {
                throw MirmirPackagedEvidenceErrorV4.invalidRequest(
                    "CodeDirectory architecture is invalid"
                )
            }
            try requireHex(
                row.sha256,
                lengths: [64],
                label: "CodeDirectory"
            )
        }
        guard !bundleIdentifier.isEmpty,
              !productVersion.isEmpty,
              !productBuild.isEmpty else {
            throw MirmirPackagedEvidenceErrorV4.invalidRequest(
                "application bundle identity is missing"
            )
        }
    }

    private func requireHex(
        _ value: String,
        lengths: Set<Int>,
        label: String
    ) throws {
        guard lengths.contains(value.utf8.count),
              MirmirNotarizedSmokeFilesV4.isLowercaseHex(value) else {
            throw MirmirPackagedEvidenceErrorV4.invalidRequest(
                "\(label) is not lowercase hexadecimal"
            )
        }
    }
}

private struct MirmirPackagedEvidenceRequestV4: Codable, Sendable {
    static let schema = "mirmir-v4-packaged-evidence-request-v1"

    let schemaVersion: String
    let lane: MirmirPackagedEvidenceLaneV4
    let requestID: String
    let nonce: String
    let generatedAtUTC: String
    let observerSourceSHA256: String
    let contractSHA256: String
    let packageIdentity: MirmirPackagedCandidateIdentityV4
    let captureEnvironment: [String: String]

    func validate() throws {
        guard schemaVersion == Self.schema,
              let uuid = UUID(uuidString: requestID),
              uuid.uuidString.lowercased() == requestID else {
            throw MirmirPackagedEvidenceErrorV4.invalidRequest(
                "request schema or canonical UUID differs"
            )
        }
        try packageIdentity.validate()
        for (label, value) in [
            ("nonce", nonce),
            ("observerSourceSHA256", observerSourceSHA256),
            ("contractSHA256", contractSHA256)
        ] {
            guard value.utf8.count == 64,
                  MirmirNotarizedSmokeFilesV4.isLowercaseHex(value) else {
                throw MirmirPackagedEvidenceErrorV4.invalidRequest(
                    "\(label) is not lowercase SHA-256"
                )
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let generated = formatter.date(from: generatedAtUTC),
              Date().timeIntervalSince(generated) >= -30,
              Date().timeIntervalSince(generated) <= 300 else {
            throw MirmirPackagedEvidenceErrorV4.staleRequest
        }
        let required: Set<String>
        switch lane {
        case .quality:
            required = [
                "MIRMIR_V4_QUALITY_CAPTURE_DIR",
                "MIRMIR_V4_QUALITY_CORPUS_MANIFEST",
                "MIRMIR_V4_QUALITY_CONTRACT_SHA256",
                "MIRMIR_V4_QUALITY_SOURCE_COMMIT",
                "MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256"
            ]
        case .parity:
            required = [
                "MIRMIR_PARITY_CAPTURE_DIRECTORY",
                "MIRMIR_PARITY_CONTRACT_PATH",
                "MIRMIR_PARITY_CONTRACT_SHA256",
                "MIRMIR_PARITY_CAPTURE_SOURCE_SHA256",
                "MIRMIR_PARITY_SOURCE_REVISION",
                "MIRMIR_PARITY_BUILD_CONFIGURATION",
                "MIRMIR_PARITY_PROCESS_RUN_ID",
                "MIRMIR_PARITY_RUNTIME_MODE"
            ]
        case .performance:
            required = [
                "MIRMIR_V4_PERFORMANCE_CAPTURE_DIR",
                "MIRMIR_V4_PERFORMANCE_INPUT",
                "MIRMIR_V4_PERFORMANCE_VARIANT",
                "MIRMIR_V4_PERFORMANCE_CONTRACT_SHA256",
                "MIRMIR_V4_PERFORMANCE_CAPTURE_SOURCE_SHA256",
                "MIRMIR_V4_PERFORMANCE_SOURCE_IDENTITY_SHA256",
                "MIRMIR_V4_PERFORMANCE_SOURCE_REVISION",
                "MIRMIR_V4_PERFORMANCE_SOURCE_TREE_SHA256",
                "MIRMIR_V4_PERFORMANCE_WARMUPS",
                "MIRMIR_V4_PERFORMANCE_SAMPLES"
            ]
        case .media:
            required = [
                "MIRMIR_V4_MEDIA_CAPTURE_DIR",
                "MIRMIR_V4_MEDIA_CONTRACT_PATH",
                "MIRMIR_V4_MEDIA_CONTRACT_SHA256",
                "MIRMIR_V4_MEDIA_FIXTURE_MANIFEST",
                "MIRMIR_V4_MEDIA_FIXTURE_MANIFEST_SHA256",
                "MIRMIR_V4_MEDIA_FIXTURE_TREE_SHA256",
                "MIRMIR_V4_MEDIA_FIXTURE_SOURCE_SHA256",
                "MIRMIR_V4_MEDIA_GENERATOR_SOURCE_SHA256",
                "MIRMIR_V4_MEDIA_SOURCE_COMMIT",
                "MIRMIR_V4_MEDIA_SOURCE_TREE_SHA256"
            ]
        case .recovery:
            required = [
                "MIRMIR_V4_RECOVERY_CAPTURE_DIR",
                "MIRMIR_V4_RECOVERY_CONTRACT_PATH",
                "MIRMIR_V4_RECOVERY_CONTRACT_SHA256",
                "MIRMIR_V4_RECOVERY_PRODUCER_SOURCE_SHA256",
                "MIRMIR_V4_RECOVERY_SOURCE_COMMIT",
                "MIRMIR_V4_RECOVERY_SOURCE_TREE_SHA256"
            ]
        }
        guard Set(captureEnvironment.keys) == required,
              captureEnvironment.values.allSatisfy({ !$0.isEmpty }) else {
            throw MirmirPackagedEvidenceErrorV4.invalidRequest(
                "capture environment field set differs"
            )
        }
        switch lane {
        case .quality:
            guard captureEnvironment[
                "MIRMIR_V4_QUALITY_CONTRACT_SHA256"
            ] == contractSHA256,
            captureEnvironment["MIRMIR_V4_QUALITY_SOURCE_COMMIT"]
                == packageIdentity.sourceCommit,
            captureEnvironment["MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256"]
                == packageIdentity.sourceTreeIdentitySHA256 else {
                throw MirmirPackagedEvidenceErrorV4.invalidRequest(
                    "quality capture identity differs from the package"
                )
            }
        case .parity:
            guard captureEnvironment["MIRMIR_PARITY_CONTRACT_SHA256"]
                    == contractSHA256,
                  captureEnvironment["MIRMIR_PARITY_CAPTURE_SOURCE_SHA256"]
                    == observerSourceSHA256,
                  captureEnvironment["MIRMIR_PARITY_SOURCE_REVISION"]
                    == packageIdentity.sourceCommit,
                  captureEnvironment["MIRMIR_PARITY_BUILD_CONFIGURATION"]
                    == "Release",
                  captureEnvironment["MIRMIR_PARITY_RUNTIME_MODE"]
                    == "production" else {
                throw MirmirPackagedEvidenceErrorV4.invalidRequest(
                    "parity capture identity differs from the package"
                )
            }
        case .performance:
            guard captureEnvironment[
                    "MIRMIR_V4_PERFORMANCE_CONTRACT_SHA256"
                  ] == contractSHA256,
                  captureEnvironment["MIRMIR_V4_PERFORMANCE_VARIANT"]
                    == "candidate_p06",
                  captureEnvironment[
                    "MIRMIR_V4_PERFORMANCE_SOURCE_REVISION"
                  ] == packageIdentity.sourceCommit,
                  captureEnvironment[
                    "MIRMIR_V4_PERFORMANCE_SOURCE_TREE_SHA256"
                  ] == packageIdentity.sourceTreeIdentitySHA256 else {
                throw MirmirPackagedEvidenceErrorV4.invalidRequest(
                    "performance capture identity differs from the package"
                )
            }
        case .media:
            guard captureEnvironment["MIRMIR_V4_MEDIA_CONTRACT_SHA256"]
                    == contractSHA256,
                  captureEnvironment["MIRMIR_V4_MEDIA_SOURCE_COMMIT"]
                    == packageIdentity.sourceCommit,
                  captureEnvironment["MIRMIR_V4_MEDIA_SOURCE_TREE_SHA256"]
                    == packageIdentity.sourceTreeIdentitySHA256 else {
                throw MirmirPackagedEvidenceErrorV4.invalidRequest(
                    "media capture identity differs from the package"
                )
            }
        case .recovery:
            guard captureEnvironment[
                    "MIRMIR_V4_RECOVERY_CONTRACT_SHA256"
                  ] == contractSHA256,
                  captureEnvironment[
                    "MIRMIR_V4_RECOVERY_SOURCE_COMMIT"
                  ] == packageIdentity.sourceCommit,
                  captureEnvironment[
                    "MIRMIR_V4_RECOVERY_SOURCE_TREE_SHA256"
                  ] == packageIdentity.sourceTreeIdentitySHA256,
                  let producerSourceSHA256 = captureEnvironment[
                    "MIRMIR_V4_RECOVERY_PRODUCER_SOURCE_SHA256"
                  ],
                  producerSourceSHA256.utf8.count == 64,
                  MirmirNotarizedSmokeFilesV4.isLowercaseHex(
                    producerSourceSHA256
                  ) else {
                throw MirmirPackagedEvidenceErrorV4.invalidRequest(
                    "recovery capture identity differs from the package"
                )
            }
        }
        try validatePaths()
    }

    private func validatePaths() throws {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw MirmirPackagedEvidenceErrorV4.unsafePath(
                "application support is unavailable"
            )
        }
        let root = support
            .appendingPathComponent("MirmirQualificationV4", isDirectory: true)
            .appendingPathComponent("packaged-evidence", isDirectory: true)
            .appendingPathComponent(requestID, isDirectory: true)
            .standardizedFileURL
        let outputKey: String
        switch lane {
        case .quality:
            outputKey = "MIRMIR_V4_QUALITY_CAPTURE_DIR"
        case .parity:
            outputKey = "MIRMIR_PARITY_CAPTURE_DIRECTORY"
        case .performance:
            outputKey = "MIRMIR_V4_PERFORMANCE_CAPTURE_DIR"
        case .media:
            outputKey = "MIRMIR_V4_MEDIA_CAPTURE_DIR"
        case .recovery:
            outputKey = "MIRMIR_V4_RECOVERY_CAPTURE_DIR"
        }
        guard let outputValue = captureEnvironment[outputKey] else {
            throw MirmirPackagedEvidenceErrorV4.unsafePath("output is absent")
        }
        let output = URL(fileURLWithPath: outputValue).standardizedFileURL
        guard output.path == root.appendingPathComponent(
            "capture",
            isDirectory: true
        ).path else {
            throw MirmirPackagedEvidenceErrorV4.unsafePath(output.path)
        }
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let paths: [String]
        switch lane {
        case .quality:
            paths = [captureEnvironment["MIRMIR_V4_QUALITY_CORPUS_MANIFEST"]!]
        case .parity:
            paths = [captureEnvironment["MIRMIR_PARITY_CONTRACT_PATH"]!]
        case .performance:
            paths = [captureEnvironment["MIRMIR_V4_PERFORMANCE_INPUT"]!]
        case .media:
            paths = [
                captureEnvironment["MIRMIR_V4_MEDIA_CONTRACT_PATH"]!,
                captureEnvironment["MIRMIR_V4_MEDIA_FIXTURE_MANIFEST"]!
            ]
        case .recovery:
            paths = [
                captureEnvironment["MIRMIR_V4_RECOVERY_CONTRACT_PATH"]!
            ]
        }
        for value in paths {
            let url = URL(fileURLWithPath: value).standardizedFileURL
            guard url.path.hasPrefix(inputs.path + "/") else {
                throw MirmirPackagedEvidenceErrorV4.unsafePath(url.path)
            }
        }
    }
}

private enum MirmirPackagedEvidenceErrorV4: Error, LocalizedError {
    case invalidInvocation
    case invalidRequest(String)
    case staleRequest
    case identityMismatch(String)
    case unsafePath(String)
    case capture(String)

    var errorDescription: String? {
        switch self {
        case .invalidInvocation:
            "The packaged-evidence invocation is malformed."
        case .invalidRequest(let value):
            "The packaged-evidence request is invalid: \(value)"
        case .staleRequest:
            "The packaged-evidence request is stale or future-dated."
        case .identityMismatch(let value):
            "The packaged candidate identity differs: \(value)"
        case .unsafePath(let value):
            "The packaged-evidence path is unsafe: \(value)"
        case .capture(let value):
            "The packaged-evidence capture failed: \(value)"
        }
    }
}

private struct MirmirPackagedCaptureTreeV4: Codable, Sendable {
    let byteCount: Int
    let fileCount: Int
    let sha256: String
}

private enum MirmirPackagedEvidenceObserverV4 {
    static let resultSchema = "mirmir-v4-packaged-evidence-result-v1"

    static func runAndExit() async -> Never {
        do {
            let invocation = try MirmirPackagedEvidenceInvocationV4.parse()
            let result = try await run(
                invocation.request,
                requestData: invocation.canonicalData
            )
            MirmirNotarizedSmokeObserverV4.emit(
                prefix: MirmirPackagedEvidenceInvocationV4.resultPrefix,
                data: result
            )
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            let payload: [String: Any] = [
                "schemaVersion": "mirmir-v4-packaged-evidence-error-v1",
                "errorType": String(reflecting: type(of: error)),
                "message": (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
            ]
            let data = (try? MirmirNotarizedSmokeFilesV4.canonicalData(payload))
                ?? Data("{\"schemaVersion\":\"mirmir-v4-packaged-evidence-error-v1\"}".utf8)
            MirmirNotarizedSmokeObserverV4.emit(
                prefix: MirmirPackagedEvidenceInvocationV4.errorPrefix,
                data: data
            )
            Darwin.exit(70)
        }
    }

    static func run(
        _ request: MirmirPackagedEvidenceRequestV4,
        requestData: Data
    ) async throws -> Data {
        try validateProcessAndRuntime(request)
        let requestSHA256 = MirmirNotarizedSmokeFilesV4.sha256(requestData)
        let manifestURL: URL
        switch request.lane {
        case .quality:
            manifestURL = try await MirmirPackagedQualityCaptureV4.capture(
                environment: request.captureEnvironment,
                packageIdentity: request.packageIdentity,
                requestSHA256: requestSHA256,
                observerSourceSHA256: request.observerSourceSHA256
            )
        case .parity:
            manifestURL = try await MirmirPackagedParityCaptureV4.capture(
                environment: request.captureEnvironment,
                packageIdentity: request.packageIdentity,
                requestSHA256: requestSHA256
            )
        case .performance:
            manifestURL = try await MirmirPackagedPerformanceCaptureV4.capture(
                environment: request.captureEnvironment,
                packageIdentity: request.packageIdentity,
                requestSHA256: requestSHA256,
                observerSourceSHA256: request.observerSourceSHA256
            )
        case .media:
            manifestURL = try await MirmirPackagedMediaCaptureV4.capture(
                environment: request.captureEnvironment,
                packageIdentity: request.packageIdentity,
                requestSHA256: requestSHA256,
                nonceSHA256: MirmirNotarizedSmokeFilesV4.sha256(
                    Data(request.nonce.utf8)
                ),
                observerSourceSHA256: request.observerSourceSHA256
            )
        case .recovery:
            manifestURL = try await MirmirPackagedRecoveryCaptureV4.capture(
                environment: request.captureEnvironment,
                packageIdentity: request.packageIdentity,
                requestID: request.requestID,
                requestSHA256: requestSHA256,
                nonceSHA256: MirmirNotarizedSmokeFilesV4.sha256(
                    Data(request.nonce.utf8)
                ),
                observerSourceSHA256: request.observerSourceSHA256
            )
        }
        let output = manifestURL.deletingLastPathComponent()
        let tree = try captureTree(output)
        let executable = try requireExecutable()
        let runtime = try ASHP06RuntimeProviderV4.production().load()
        try runtime.verifyBinding()
        let result: [String: Any] = [
            "schemaVersion": resultSchema,
            "lane": request.lane.rawValue,
            "requestID": request.requestID,
            "requestSHA256": requestSHA256,
            "observerSourceSHA256": request.observerSourceSHA256,
            "contractSHA256": request.contractSHA256,
            "packageIdentity": try MirmirNotarizedSmokeFilesV4.object(
                request.packageIdentity
            ),
            "process": [
                "bundlePath": Bundle.main.bundleURL.standardizedFileURL.path,
                "executablePath": executable.standardizedFileURL.path,
                "executableSHA256": try MirmirNotarizedSmokeFilesV4.sha256(
                    executable
                ),
                "processID": ProcessInfo.processInfo.processIdentifier,
                "parentProcessID": getppid()
            ],
            "runtime": [
                "runtimeID": runtime.manifest.runtimeID,
                "releaseStatus": runtime.manifest.releaseStatus.rawValue,
                "manifestSHA256": runtime.manifestSHA256.rawValue,
                "sourceRevision": runtime.manifest.provenance.sourceRevision,
                "trustRootConfigured": ASHProductionP06TrustRootV4.isConfigured
            ],
            "captureManifest": [
                "fileName": manifestURL.lastPathComponent,
                "byteCount": try manifestURL.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize ?? -1,
                "sha256": try MirmirNotarizedSmokeFilesV4.sha256(manifestURL)
            ],
            "captureTree": try MirmirNotarizedSmokeFilesV4.object(tree),
            "checks": [
                "exactExecutableIdentity": true,
                "signedBuildClaims": true,
                "productionP06Load": true,
                "normativePixelCapture": true
            ]
        ]
        return try MirmirNotarizedSmokeFilesV4.canonicalData(result)
    }

    private static func validateProcessAndRuntime(
        _ request: MirmirPackagedEvidenceRequestV4
    ) throws {
        let identity = request.packageIdentity
        let executable = try requireExecutable()
        guard try MirmirNotarizedSmokeFilesV4.sha256(executable)
                == identity.applicationExecutableSHA256,
              Bundle.main.bundleIdentifier == identity.bundleIdentifier,
              Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String == identity.productVersion,
              Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String == identity.productBuild else {
            throw MirmirPackagedEvidenceErrorV4.identityMismatch(
                "bundle or executable"
            )
        }
        let claims: [(String, String)] = [
            ("MirmirV4BuildConfiguration", "Release"),
            ("MirmirV4SourceCommit", identity.sourceCommit),
            (
                "MirmirV4SourceTreeIdentitySHA256",
                identity.sourceTreeIdentitySHA256
            ),
            (
                "MirmirV4ReleaseConfigurationSHA256",
                identity.releaseConfigurationSHA256
            ),
            (
                "MirmirV4RuntimeManifestSHA256",
                identity.runtimeManifestSHA256
            ),
            (
                "MirmirV4RuntimeManifestFileSHA256",
                identity.runtimeManifestFileSHA256
            ),
            (
                "MirmirV4RuntimeArtifactSetSHA256",
                identity.runtimeArtifactSetSHA256
            ),
            (
                "MirmirV4RuntimeSourceRevision",
                identity.runtimeSourceRevision
            )
        ]
        for (key, expected) in claims where
            Bundle.main.object(forInfoDictionaryKey: key) as? String
                != expected {
            throw MirmirPackagedEvidenceErrorV4.identityMismatch(
                "signed build claim \(key)"
            )
        }
        guard ASHProductionP06TrustRootV4.isConfigured else {
            throw MirmirPackagedEvidenceErrorV4.identityMismatch(
                "production P06 trust root"
            )
        }
        let runtime = try ASHP06RuntimeProviderV4.production().load()
        try runtime.verifyBinding()
        try runtime.manifest.validate(requiring: .releaseQualified)
        let manifestFile = runtime.bundleURL.appendingPathComponent(
            ASHRuntimeManifestV4.fileName
        )
        guard runtime.manifestSHA256.rawValue
                == identity.runtimeManifestSHA256,
              try MirmirNotarizedSmokeFilesV4.sha256(manifestFile)
                == identity.runtimeManifestFileSHA256,
              runtime.manifest.provenance.sourceRevision
                == identity.runtimeSourceRevision else {
            throw MirmirPackagedEvidenceErrorV4.identityMismatch(
                "embedded production runtime"
            )
        }
    }

    private static func requireExecutable() throws -> URL {
        guard let executable = Bundle.main.executableURL,
              executable.isFileURL else {
            throw MirmirPackagedEvidenceErrorV4.identityMismatch(
                "main executable is absent"
            )
        }
        return executable
    }

    private static func captureTree(
        _ root: URL
    ) throws -> MirmirPackagedCaptureTreeV4 {
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
                atPath: root.path,
                isDirectory: &isDirectory
              ),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ],
                options: []
              ) else {
            throw MirmirPackagedEvidenceErrorV4.capture(
                "capture root is unavailable"
            )
        }
        let values = (enumerator.allObjects as? [URL] ?? []).sorted {
            $0.path < $1.path
        }
        var digest = SHA256()
        digest.update(data: Data("mirmir-packaged-capture-tree-v1\0".utf8))
        var bytes = 0
        var files = 0
        for url in values {
            let resource = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            guard resource.isSymbolicLink != true else {
                throw MirmirPackagedEvidenceErrorV4.capture(
                    "capture tree contains a symbolic link"
                )
            }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            digest.update(data: Data(relative.utf8))
            digest.update(data: Data([0]))
            if resource.isDirectory == true {
                digest.update(data: Data("directory\n".utf8))
            } else if resource.isRegularFile == true {
                let size = resource.fileSize ?? -1
                guard size >= 0 else {
                    throw MirmirPackagedEvidenceErrorV4.capture(
                        "capture file size is invalid"
                    )
                }
                bytes += size
                files += 1
                guard bytes <= 8 * 1_024 * 1_024 * 1_024 else {
                    throw MirmirPackagedEvidenceErrorV4.capture(
                        "capture tree exceeds 8 GiB"
                    )
                }
                digest.update(data: Data("file\0".utf8))
                digest.update(data: Data(
                    try MirmirNotarizedSmokeFilesV4.sha256(url).utf8
                ))
                digest.update(data: Data("\n".utf8))
            } else {
                throw MirmirPackagedEvidenceErrorV4.capture(
                    "capture tree contains a special file"
                )
            }
        }
        return MirmirPackagedCaptureTreeV4(
            byteCount: bytes,
            fileCount: files,
            sha256: MirmirNotarizedSmokeFilesV4.hex(digest.finalize())
        )
    }
}

// MARK: - Exact packaged-candidate media preservation observer

private enum MirmirPackagedMediaErrorV4: Error {
    case invalid(String)
    case reader
    case coreVideo(CVReturn)
    case coreMedia(OSStatus)
}

private struct MirmirPackagedMediaAlphaOracleInputV4: Codable, Sendable {
    let schemaVersion: String
    let path: String
    let byteCount: Int
    let sha256: String
    let frameSHA256: [String]
    let frameCount: Int
    let width: Int
    let height: Int
    let association: String
}

private struct MirmirPackagedMediaFixtureV4: Codable, Sendable {
    let id: String
    let policy: String
    let coverage: [String]
    let sourceFile: String
    let sourceByteCount: Int
    let sourceSHA256: String
    let targetWidth: Int
    let targetHeight: Int
    let outputCodec: String
    let expectedProcessedFrameCount: Int
    let alphaOracleInput: MirmirPackagedMediaAlphaOracleInputV4?
}

private struct MirmirPackagedMediaFixturePackageV4: Codable, Sendable {
    let schemaVersion: String
    let suiteID: String
    let fixtures: [MirmirPackagedMediaFixtureV4]
}

private struct MirmirPackagedMediaPreflightV4: Codable, Equatable,
    Sendable {
    static let schema = "mirmir-ash-v4-media-independent-preflight-v2"

    let schemaVersion: String
    let preparedBackendType: String
    let executor: ASHExecutorV4
    let requestedBackendID: UpscaleBackendID
    let ashPlanSHA256: ASHSHA256V4
    let runtimeManifestSHA256: ASHSHA256V4
    let runtimeProvenanceSHA256: ASHSHA256V4
    let trackPlanSHA256: ASHSHA256V4
    let sourceGraphSHA256: ASHSHA256V4
    let migrationBlueprintSHA256: ASHSHA256V4
    let primaryTrackOrdinal: Int
    let plannedTracks: [DeterministicV4MediaPlannedTrackReceiptV4]
    let targetWidth: Int
    let targetHeight: Int
    let sourceVideoTrackCount: Int
    let sourceAudioTrackCount: Int
    let plannedEnabledTrackCount: Int

    init(
        request: UpscaleRequest,
        backend: any PreparedDeterministicV4RuntimePlanningBackend,
        plan: DeterministicV4PreparedAssetPlan
    ) throws {
        let enabled = plan.sourceGraph.tracks.filter(\.enabled)
        schemaVersion = Self.schema
        preparedBackendType = String(reflecting: type(of: backend))
        executor = backend.deterministicExecutor
        requestedBackendID = request.backendID
        ashPlanSHA256 = plan.ashPlan.planSHA256
        runtimeManifestSHA256 = plan.ashPlan.plan.runtimeManifestSHA256
        runtimeProvenanceSHA256 = plan.ashPlan.plan.runtimeProvenanceSHA256
        trackPlanSHA256 = plan.trackPlan.planSHA256
        sourceGraphSHA256 = try plan.sourceGraph.canonicalSHA256
        migrationBlueprintSHA256 = try plan.migrationBlueprint.canonicalSHA256
        primaryTrackOrdinal = Int(plan.primaryGraphTrack.identity.ordinal)
        plannedTracks = plan.trackPlan.plan.tracks.map {
            DeterministicV4MediaPlannedTrackReceiptV4(
                ordinal: Int($0.source.identity.ordinal),
                stableID: $0.source.identity.stableID.rawValue,
                kind: $0.source.kind.rawValue,
                action: $0.action
            )
        }
        targetWidth = request.targetWidth
        targetHeight = request.targetHeight
        sourceVideoTrackCount = enabled.filter { $0.kind == .video }.count
        sourceAudioTrackCount = enabled.filter { $0.kind == .audio }.count
        plannedEnabledTrackCount = enabled.count
    }

    func verify(
        _ receipt: DeterministicV4MediaExecutionReceiptV4,
        fixture: MirmirPackagedMediaFixtureV4
    ) throws {
        let expectedType = fixture.alphaOracleInput == nil
            ? "Mirmir.PreparedDeterministicV4Upscaler"
            : "Mirmir.PreparedDeterministicAlphaPlanningBackendV4"
        let expectedMigratedTracks = plannedTracks.filter({
            $0.action != .dropWithConsent
        })
        guard schemaVersion == Self.schema,
              preparedBackendType == expectedType,
              receipt.schemaID
                == DeterministicV4MediaExecutionReceiptV4.currentSchemaID,
              receipt.preparedBackendType == preparedBackendType,
              receipt.executor == executor,
              receipt.requestedBackendID == requestedBackendID,
              receipt.actualBackendID == .mirmirDeterministicCPU,
              receipt.ashPlanSHA256 == ashPlanSHA256,
              receipt.runtimeManifestSHA256 == runtimeManifestSHA256,
              receipt.runtimeProvenanceSHA256 == runtimeProvenanceSHA256,
              receipt.trackPlanSHA256 == trackPlanSHA256,
              receipt.sourceGraphSHA256 == sourceGraphSHA256,
              receipt.migrationSourceGraphSHA256 == sourceGraphSHA256,
              receipt.migrationPlanSHA256 == trackPlanSHA256,
              receipt.migrationBlueprintSHA256
                == migrationBlueprintSHA256,
              receipt.primaryTrackOrdinal == primaryTrackOrdinal,
              receipt.plannedTracks == plannedTracks,
              receipt.migratedTracks.count == expectedMigratedTracks.count,
              zip(
                  receipt.migratedTracks,
                  expectedMigratedTracks
              ).allSatisfy({ migrated, planned in
                  migrated.stableID == planned.stableID
                      && migrated.action == planned.action
              }),
              receipt.targetWidth == targetWidth,
              receipt.targetHeight == targetHeight,
              receipt.encodedWidth == targetWidth,
              receipt.encodedHeight == targetHeight,
              receipt.processedFrameCount
                == fixture.expectedProcessedFrameCount,
              receipt.sourceVideoTrackCount == sourceVideoTrackCount,
              receipt.sourceAudioTrackCount == sourceAudioTrackCount,
              receipt.plannedEnabledTrackCount == plannedEnabledTrackCount,
              receipt.sourceAssetMetadataSHA256
                == receipt.outputAssetMetadataSHA256,
              receipt.sourceChapterMetadataSHA256
                == receipt.outputChapterMetadataSHA256,
              (fixture.alphaOracleInput != nil)
                == (receipt.alphaVerification != nil) else {
            throw MirmirPackagedMediaErrorV4.invalid(
                "actual session receipt differs from independent preflight: \(fixture.id)"
            )
        }
    }
}

private enum MirmirPackagedMediaJSONV4 {
    static func object(from data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? [String: Any] else {
            throw MirmirPackagedMediaErrorV4.invalid("JSON object")
        }
        return value
    }

    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try object(from: JSONEncoder().encode(value))
    }

    static func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func write(_ value: Any, to url: URL) throws {
        var bytes = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        bytes.append(0x0A)
        try bytes.write(to: url, options: .atomic)
    }

    static func hash(_ value: Any) throws -> String {
        MirmirNotarizedSmokeFilesV4.sha256(try data(value))
    }

    static func requireExactKeys(
        _ value: [String: Any],
        _ expected: Set<String>,
        _ label: String
    ) throws {
        guard Set(value.keys) == expected else {
            throw MirmirPackagedMediaErrorV4.invalid(
                "\(label) field set differs"
            )
        }
    }
}

private enum MirmirPackagedRecoveryCaptureV4 {
    static func capture(
        environment: [String: String],
        packageIdentity: MirmirPackagedCandidateIdentityV4,
        requestID: String,
        requestSHA256: String,
        nonceSHA256: String,
        observerSourceSHA256: String
    ) async throws -> URL {
        let captureRoot = try requiredURL(
            environment,
            "MIRMIR_V4_RECOVERY_CAPTURE_DIR"
        )
        let contractURL = try requiredURL(
            environment,
            "MIRMIR_V4_RECOVERY_CONTRACT_PATH"
        )
        guard let contractSHA256 = environment[
                "MIRMIR_V4_RECOVERY_CONTRACT_SHA256"
              ],
              let producerSourceSHA256 = environment[
                "MIRMIR_V4_RECOVERY_PRODUCER_SOURCE_SHA256"
              ],
              try MirmirNotarizedSmokeFilesV4.sha256(contractURL)
                == contractSHA256 else {
            throw MirmirPackagedEvidenceErrorV4.capture(
                "the staged recovery contract identity differs"
            )
        }
        let packaged = RecoveryQualificationPackageIdentityV4(
            schemaVersion: packageIdentity.schemaVersion,
            buildConfiguration: packageIdentity.buildConfiguration,
            applicationArchiveSHA256:
                packageIdentity.applicationArchiveSHA256,
            applicationPayloadIdentitySHA256:
                packageIdentity.applicationPayloadIdentitySHA256,
            applicationInfoPlistSHA256:
                packageIdentity.applicationInfoPlistSHA256,
            applicationExecutableSHA256:
                packageIdentity.applicationExecutableSHA256,
            codeDirectories: packageIdentity.codeDirectories.map {
                RecoveryQualificationCodeDirectoryV4(
                    architecture: $0.architecture,
                    sha256: $0.sha256
                )
            },
            codeDirectorySetSHA256: packageIdentity.codeDirectorySetSHA256,
            designatedRequirementSHA256:
                packageIdentity.designatedRequirementSHA256,
            releaseConfigurationSHA256:
                packageIdentity.releaseConfigurationSHA256,
            attestationSHA256: packageIdentity.attestationSHA256,
            sourceCommit: packageIdentity.sourceCommit,
            sourceTreeIdentitySHA256:
                packageIdentity.sourceTreeIdentitySHA256,
            runtimeManifestSHA256: packageIdentity.runtimeManifestSHA256,
            runtimeManifestFileSHA256:
                packageIdentity.runtimeManifestFileSHA256,
            runtimeArtifactSetSHA256:
                packageIdentity.runtimeArtifactSetSHA256,
            runtimeSourceRevision: packageIdentity.runtimeSourceRevision,
            bundleIdentifier: packageIdentity.bundleIdentifier,
            productVersion: packageIdentity.productVersion,
            productBuild: packageIdentity.productBuild
        )
        let execution = RecoveryQualificationPackagedExecutionV4(
            requestID: requestID,
            requestSHA256: requestSHA256,
            nonceSHA256: nonceSHA256,
            observerSourceSHA256: observerSourceSHA256,
            packageIdentity: packaged
        )
        return try await RecoveryQualificationProducerV4().capture(.init(
            captureRootURL: captureRoot,
            contractURL: contractURL,
            contractSHA256: contractSHA256,
            producerSourceSHA256: producerSourceSHA256,
            execution: execution
        ))
    }

    private static func requiredURL(
        _ environment: [String: String],
        _ key: String
    ) throws -> URL {
        guard let value = environment[key], !value.isEmpty else {
            throw MirmirPackagedEvidenceErrorV4.capture(
                "the recovery path \(key) is absent"
            )
        }
        return URL(fileURLWithPath: value).standardizedFileURL
    }
}

private enum MirmirPackagedMediaCaptureV4 {
    private struct Execution {
        let preflight: MirmirPackagedMediaPreflightV4
        let value: DeterministicV4MediaProcessingExecutionV4
    }

    static func capture(
        environment: [String: String],
        packageIdentity: MirmirPackagedCandidateIdentityV4,
        requestSHA256: String,
        nonceSHA256: String,
        observerSourceSHA256: String
    ) async throws -> URL {
        let output = try requiredURL(
            environment,
            "MIRMIR_V4_MEDIA_CAPTURE_DIR"
        )
        let manifestURL = try requiredURL(
            environment,
            "MIRMIR_V4_MEDIA_FIXTURE_MANIFEST"
        )
        let contractURL = try requiredURL(
            environment,
            "MIRMIR_V4_MEDIA_CONTRACT_PATH"
        )
        let inputRoot = manifestURL.deletingLastPathComponent()
        guard try MirmirNotarizedSmokeFilesV4.sha256(manifestURL)
                == environment["MIRMIR_V4_MEDIA_FIXTURE_MANIFEST_SHA256"],
              try MirmirNotarizedSmokeFilesV4.sha256(contractURL)
                == environment["MIRMIR_V4_MEDIA_CONTRACT_SHA256"],
              try inputTreeSHA256(inputRoot)
                == environment["MIRMIR_V4_MEDIA_FIXTURE_TREE_SHA256"] else {
            throw MirmirPackagedMediaErrorV4.invalid(
                "staged media input identity differs"
            )
        }
        let packageData = try Data(contentsOf: manifestURL)
        let packageObject = try MirmirPackagedMediaJSONV4.object(
            from: packageData
        )
        try validateFixturePackageKeys(packageObject)
        let fixturePackage = try JSONDecoder().decode(
            MirmirPackagedMediaFixturePackageV4.self,
            from: packageData
        )
        let contractObject = try MirmirPackagedMediaJSONV4.object(
            from: Data(contentsOf: contractURL)
        )
        try validate(
            fixturePackage: fixturePackage,
            contract: contractObject,
            root: inputRoot
        )
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: false
        )
        var capturedFixtures: [[String: Any]] = []
        for fixture in fixturePackage.fixtures {
            capturedFixtures.append(try await captureFixture(
                fixture,
                inputRoot: inputRoot,
                captureRoot: output,
                packageIdentity: packageIdentity,
                requestSHA256: requestSHA256,
                nonceSHA256: nonceSHA256
            ))
        }
        let capture: [String: Any] = [
            "schemaVersion":
                "mirmir-ash-v4-media-preservation-capture-v2",
            "suiteID": fixturePackage.suiteID,
            "evidenceRequestSHA256": requestSHA256,
            "evidenceNonceSHA256": nonceSHA256,
            "observerSourceSHA256": observerSourceSHA256,
            "laneContractSHA256": environment[
                "MIRMIR_V4_MEDIA_CONTRACT_SHA256"
            ]!,
            "fixtureManifestSHA256": environment[
                "MIRMIR_V4_MEDIA_FIXTURE_MANIFEST_SHA256"
            ]!,
            "fixtureTreeSHA256": environment[
                "MIRMIR_V4_MEDIA_FIXTURE_TREE_SHA256"
            ]!,
            "fixtureSourceSHA256": environment[
                "MIRMIR_V4_MEDIA_FIXTURE_SOURCE_SHA256"
            ]!,
            "generatorSourceSHA256": environment[
                "MIRMIR_V4_MEDIA_GENERATOR_SOURCE_SHA256"
            ]!,
            "packagedCandidateIdentity": try MirmirPackagedMediaJSONV4
                .object(packageIdentity),
            "buildConfiguration": "Release",
            "fixtures": capturedFixtures
        ]
        let captureURL = output.appendingPathComponent("capture.json")
        try MirmirPackagedMediaJSONV4.write(capture, to: captureURL)
        return captureURL
    }

    private static func captureFixture(
        _ fixture: MirmirPackagedMediaFixtureV4,
        inputRoot: URL,
        captureRoot: URL,
        packageIdentity: MirmirPackagedCandidateIdentityV4,
        requestSHA256: String,
        nonceSHA256: String
    ) async throws -> [String: Any] {
        let fixtureRoot = captureRoot.appendingPathComponent(
            "fixtures/\(fixture.id)",
            isDirectory: true
        )
        let input = fixtureRoot.appendingPathComponent("input", isDirectory: true)
        let output = fixtureRoot.appendingPathComponent("output", isDirectory: true)
        let repeated = fixtureRoot.appendingPathComponent("repeat", isDirectory: true)
        for directory in [input, output, repeated] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let stagedSource = try safeInput(
            fixture.sourceFile,
            root: inputRoot,
            byteCount: fixture.sourceByteCount,
            sha256: fixture.sourceSHA256
        )
        let sourceURL = input.appendingPathComponent("media.mov")
        try FileManager.default.copyItem(at: stagedSource, to: sourceURL)
        let outputURL = output.appendingPathComponent("media.mov")
        let repeatURL = repeated.appendingPathComponent("media.mov")
        guard let codec = OutputCodec(rawValue: fixture.outputCodec) else {
            throw MirmirPackagedMediaErrorV4.invalid(
                "unsupported fixture codec: \(fixture.id)"
            )
        }
        let first = try await execute(
            fixture: fixture,
            sourceURL: sourceURL,
            outputURL: outputURL,
            codec: codec
        )
        let second = try await execute(
            fixture: fixture,
            sourceURL: sourceURL,
            outputURL: repeatURL,
            codec: codec
        )
        guard first.preflight == second.preflight,
              first.value.receipt == second.value.receipt,
              first.preflight.runtimeManifestSHA256.rawValue
                == packageIdentity.runtimeManifestSHA256 else {
            throw MirmirPackagedMediaErrorV4.invalid(
                "preflight/execution/runtime receipt is not repeatable or bound: \(fixture.id)"
            )
        }
        let firstAlpha = first.value.receipt.alphaVerification?.frames.map {
            $0.sourceAlphaSHA256.rawValue
        } ?? []
        let repeatAlpha = second.value.receipt.alphaVerification?.frames.map {
            $0.sourceAlphaSHA256.rawValue
        } ?? []
        guard firstAlpha == repeatAlpha else {
            throw MirmirPackagedMediaErrorV4.invalid(
                "actual pre-encode alpha is not repeatable: \(fixture.id)"
            )
        }
        let repeatPixels = try await MirmirPackagedMediaObserverV4
            .pixelIdentities(at: repeatURL)
        let inputSide = try await MirmirPackagedMediaObserverV4.captureSide(
            fixtureID: fixture.id,
            side: "input",
            mediaURL: sourceURL,
            directory: input,
            repeatVisibleSHA256: [:],
            preEncodeAlphaFrameSHA256: [:],
            repeatPreEncodeAlphaFrameSHA256: [:],
            metadata: nil
        )
        let primary = first.value.receipt.primaryTrackOrdinal
        let outputSide = try await MirmirPackagedMediaObserverV4.captureSide(
            fixtureID: fixture.id,
            side: "output",
            mediaURL: outputURL,
            directory: output,
            repeatVisibleSHA256: repeatPixels,
            preEncodeAlphaFrameSHA256: firstAlpha.isEmpty
                ? [:] : [primary: firstAlpha],
            repeatPreEncodeAlphaFrameSHA256: repeatAlpha.isEmpty
                ? [:] : [primary: repeatAlpha],
            metadata: nil
        )
        guard inputSide.enabledTrackCount == outputSide.enabledTrackCount,
              MirmirPackagedMediaObserverV4.visibleIdentities(
                outputSide.pixelObservation
              ) == repeatPixels else {
            throw MirmirPackagedMediaErrorV4.invalid(
                "captured media is not repeatable/accounted: \(fixture.id)"
            )
        }
        let preflightObject = try MirmirPackagedMediaJSONV4.object(
            first.preflight
        )
        let repeatPreflightObject = try MirmirPackagedMediaJSONV4.object(
            second.preflight
        )
        let receiptObject = try MirmirPackagedMediaJSONV4.object(
            first.value.receipt
        )
        let repeatReceiptObject = try MirmirPackagedMediaJSONV4.object(
            second.value.receipt
        )
        var route: [String: Any] = [
            "schemaVersion":
                "mirmir-ash-v4-media-production-route-receipt-v2",
            "entryPoint":
                "VideoProcessingSession.processWithDeterministicV4ExecutionReceipt",
            "executionProducer": "exact_archived_mirmir_executable",
            "dispatchRequirement":
                "PreparedDeterministicV4RuntimePlanningBackend",
            "planEvidenceBoundary":
                "actual_session_receipt_matched_independent_preflight",
            "evidenceRequestSHA256": requestSHA256,
            "evidenceNonceSHA256": nonceSHA256,
            "applicationArchiveSHA256":
                packageIdentity.applicationArchiveSHA256,
            "applicationExecutableSHA256":
                packageIdentity.applicationExecutableSHA256,
            "sourceTreeIdentitySHA256":
                packageIdentity.sourceTreeIdentitySHA256,
            "independentPreflight": preflightObject,
            "repeatIndependentPreflight": repeatPreflightObject,
            "executionReceipt": receiptObject,
            "repeatExecutionReceipt": repeatReceiptObject,
            "independentPreflightSHA256": try MirmirPackagedMediaJSONV4
                .hash(preflightObject),
            "repeatIndependentPreflightSHA256": try MirmirPackagedMediaJSONV4
                .hash(repeatPreflightObject),
            "executionReceiptSHA256": try MirmirPackagedMediaJSONV4
                .hash(receiptObject),
            "repeatExecutionReceiptSHA256": try MirmirPackagedMediaJSONV4
                .hash(repeatReceiptObject),
            "inputEnabledTrackCount": inputSide.enabledTrackCount,
            "outputEnabledTrackCount": outputSide.enabledTrackCount
        ]
        route["routeProofSHA256"] = try MirmirPackagedMediaJSONV4.hash(route)

        var alphaOracle: Any = NSNull()
        if let oracle = fixture.alphaOracleInput {
            let staged = try safeInput(
                oracle.path,
                root: inputRoot,
                byteCount: oracle.byteCount,
                sha256: oracle.sha256
            )
            let captured = input.appendingPathComponent("alpha-source.bin")
            try FileManager.default.copyItem(at: staged, to: captured)
            alphaOracle = [
                "schemaVersion": oracle.schemaVersion,
                "artifact": try MirmirPackagedMediaObserverV4.artifact(
                    captured,
                    root: captureRoot
                ),
                "frameSHA256": oracle.frameSHA256,
                "frameCount": oracle.frameCount,
                "width": oracle.width,
                "height": oracle.height,
                "association": oracle.association
            ]
        }
        return [
            "id": fixture.id,
            "coverage": fixture.coverage,
            "policy": fixture.policy,
            "enabledInputTrackCount": inputSide.enabledTrackCount,
            "accountedOutputTrackCount": outputSide.enabledTrackCount,
            "alphaOracleInput": alphaOracle,
            "production": [
                "runtimeManifestSHA256":
                    packageIdentity.runtimeManifestSHA256,
                "routeReceipt": route
            ],
            "input": inputSide.descriptors,
            "output": outputSide.descriptors
        ]
    }

    private static func execute(
        fixture: MirmirPackagedMediaFixtureV4,
        sourceURL: URL,
        outputURL: URL,
        codec: OutputCodec
    ) async throws -> Execution {
        let source = try await VideoProbe().probe(url: sourceURL)
        guard let descriptor = BackendDescriptor.descriptor(
                for: .mirmirDeterministicCPU
              ),
              let backend = DeterministicCPUBackend(descriptor: descriptor)
        else {
            throw MirmirPackagedMediaErrorV4.invalid(
                "deterministic CPU backend is unavailable"
            )
        }
        let preparation = BackendPreparationRequest(
            source: source,
            targetSize: CGSize(
                width: fixture.targetWidth,
                height: fixture.targetHeight
            )
        )
        let preflightPrepared = try await backend.prepare(
            request: preparation,
            environment: .current()
        )
        guard let preflightBackend = preflightPrepared
                as? any PreparedDeterministicV4RuntimePlanningBackend else {
            throw MirmirPackagedMediaErrorV4.invalid(
                "preflight backend lacks deterministic planning"
            )
        }
        let request = UpscaleRequest(
            inputURL: sourceURL,
            outputURL: outputURL,
            backendID: .mirmirDeterministicCPU,
            targetWidth: fixture.targetWidth,
            targetHeight: fixture.targetHeight,
            outputCodec: codec,
            preserveAudio: true,
            overwriteExistingFile: false
        )
        let plan = try await DeterministicV4WholeAssetPlanner().prepare(
            request: request,
            source: source,
            backend: preflightBackend
        )
        try plan.ashPlan.verify()
        try plan.trackPlan.verify()
        let preflight = try MirmirPackagedMediaPreflightV4(
            request: request,
            backend: preflightBackend,
            plan: plan
        )
        let productionPrepared = try await backend.prepare(
            request: preparation,
            environment: .current()
        )
        let execution = try await VideoProcessingSession()
            .processWithDeterministicV4ExecutionReceipt(
                request: request,
                source: source,
                preparedBackend: productionPrepared,
                cancellation: ProcessingCancellation(),
                progress: { _ in }
            )
        try preflight.verify(execution.receipt, fixture: fixture)
        return Execution(preflight: preflight, value: execution)
    }

    private static func validateFixturePackageKeys(
        _ package: [String: Any]
    ) throws {
        try MirmirPackagedMediaJSONV4.requireExactKeys(
            package,
            ["schemaVersion", "suiteID", "fixtures"],
            "fixture package"
        )
        guard let fixtures = package["fixtures"] as? [[String: Any]] else {
            throw MirmirPackagedMediaErrorV4.invalid("fixture package rows")
        }
        let keys: Set<String> = [
            "id", "policy", "coverage", "sourceFile", "sourceByteCount",
            "sourceSHA256", "targetWidth", "targetHeight", "outputCodec",
            "expectedProcessedFrameCount", "alphaOracleInput"
        ]
        for fixture in fixtures {
            try MirmirPackagedMediaJSONV4.requireExactKeys(
                fixture,
                keys,
                "fixture package row"
            )
        }
    }

    private static func validate(
        fixturePackage: MirmirPackagedMediaFixturePackageV4,
        contract: [String: Any],
        root: URL
    ) throws {
        guard fixturePackage.schemaVersion
                == "mirmir-ash-v4-media-fixture-package-v2",
              fixturePackage.suiteID
                == "mirmir-ash-v4-media-preservation-v1",
              fixturePackage.fixtures.count == 6,
              Set(fixturePackage.fixtures.map(\.id)).count == 6,
              contract["schemaVersion"] as? String
                == "mirmir-ash-v4-media-preservation-contract-v1",
              contract["suiteID"] as? String == fixturePackage.suiteID,
              let contractFixtures = contract["fixtures"]
                as? [[String: Any]],
              contractFixtures.count == 6 else {
            throw MirmirPackagedMediaErrorV4.invalid(
                "fixture package or contract header differs"
            )
        }
        for (fixture, locked) in zip(
            fixturePackage.fixtures,
            contractFixtures
        ) {
            guard locked["id"] as? String == fixture.id,
                  locked["policy"] as? String == fixture.policy,
                  locked["coverage"] as? [String] == fixture.coverage,
                  fixture.targetWidth > 0,
                  fixture.targetHeight > 0,
                  fixture.expectedProcessedFrameCount > 0 else {
                throw MirmirPackagedMediaErrorV4.invalid(
                    "fixture differs from lane contract: \(fixture.id)"
                )
            }
            _ = try safeInput(
                fixture.sourceFile,
                root: root,
                byteCount: fixture.sourceByteCount,
                sha256: fixture.sourceSHA256
            )
            if let alpha = fixture.alphaOracleInput {
                guard alpha.schemaVersion
                        == "mirmir-ash-v4-alpha-oracle-input-v1",
                      alpha.width == 16,
                      alpha.height == 16,
                      alpha.frameCount == 3,
                      alpha.frameSHA256.count == alpha.frameCount,
                      alpha.byteCount
                        == alpha.width * alpha.height * alpha.frameCount,
                      ["straight", "premultiplied"].contains(
                        alpha.association
                      ) else {
                    throw MirmirPackagedMediaErrorV4.invalid(
                        "alpha oracle input differs: \(fixture.id)"
                    )
                }
                _ = try safeInput(
                    alpha.path,
                    root: root,
                    byteCount: alpha.byteCount,
                    sha256: alpha.sha256
                )
            }
        }
    }

    private static func requiredURL(
        _ environment: [String: String],
        _ key: String
    ) throws -> URL {
        guard let value = environment[key], !value.isEmpty else {
            throw MirmirPackagedMediaErrorV4.invalid("missing \(key)")
        }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private static func safeInput(
        _ relative: String,
        root: URL,
        byteCount: Int,
        sha256: String
    ) throws -> URL {
        guard !relative.isEmpty,
              !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else {
            throw MirmirPackagedMediaErrorV4.invalid("unsafe input path")
        }
        let url = root.appendingPathComponent(relative).standardizedFileURL
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ])
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == byteCount,
              try MirmirNotarizedSmokeFilesV4.sha256(url) == sha256 else {
            throw MirmirPackagedMediaErrorV4.invalid(
                "input artifact identity differs"
            )
        }
        return url
    }

    private static func inputTreeSHA256(_ root: URL) throws -> String {
        let root = root.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey
            ],
            options: []
        ) else {
            throw MirmirPackagedMediaErrorV4.invalid("input tree")
        }
        let urls = (enumerator.allObjects as? [URL] ?? []).sorted {
            $0.path < $1.path
        }
        var digest = SHA256()
        digest.update(data: Data("mirmir-packaged-input-tree-v1\0".utf8))
        for url in urls {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey
            ])
            guard values.isSymbolicLink != true else {
                throw MirmirPackagedMediaErrorV4.invalid("input symlink")
            }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            digest.update(data: Data(relative.utf8))
            digest.update(data: Data([0]))
            if values.isDirectory == true {
                digest.update(data: Data("directory\n".utf8))
            } else if values.isRegularFile == true {
                digest.update(data: Data("file\0".utf8))
                digest.update(data: Data(
                    try MirmirNotarizedSmokeFilesV4.sha256(url).utf8
                ))
                digest.update(data: Data("\n".utf8))
            } else {
                throw MirmirPackagedMediaErrorV4.invalid("special input")
            }
        }
        return MirmirNotarizedSmokeFilesV4.hex(digest.finalize())
    }
}

enum MirmirPackagedMediaTimingSampleV4 {
    static func admits(_ sample: CMSampleBuffer) -> Bool {
        CMSampleBufferGetNumSamples(sample) > 0
    }
}

private enum MirmirPackagedMediaObserverV4 {
    struct MetadataIdentities {
        let asset: String
        let chapter: String
    }

    struct SideCapture {
        let enabledTrackCount: Int
        let descriptors: [String: Any]
        let pixelObservation: [String: Any]
    }

    static func captureSide(
        fixtureID: String,
        side: String,
        mediaURL: URL,
        directory: URL,
        repeatVisibleSHA256: [Int: String],
        preEncodeAlphaFrameSHA256: [Int: [String]],
        repeatPreEncodeAlphaFrameSHA256: [Int: [String]],
        metadata: MetadataIdentities?
    ) async throws -> SideCapture {
        let asset = AVURLAsset(
            url: mediaURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let graph = try await AVFoundationTrackGraphAdapterV4.probe(asset: asset)
        let observedMetadata: MetadataIdentities
        if let metadata {
            observedMetadata = metadata
        } else {
            observedMetadata = try await metadataIdentities(for: asset)
        }
        let tracks = try trackObservation(
            fixtureID: fixtureID,
            side: side,
            graph: graph,
            metadata: observedMetadata
        )
        let timing = try await timingObservation(
            fixtureID: fixtureID,
            side: side,
            asset: asset
        )
        let pixelResult = try await pixelObservation(
            fixtureID: fixtureID,
            side: side,
            asset: asset,
            directory: directory,
            repeatVisibleSHA256: repeatVisibleSHA256,
            preEncodeAlphaFrameSHA256: preEncodeAlphaFrameSHA256,
            repeatPreEncodeAlphaFrameSHA256:
                repeatPreEncodeAlphaFrameSHA256
        )
        let attachments = try await attachmentObservation(
            fixtureID: fixtureID,
            side: side,
            mediaURL: mediaURL,
            asset: asset
        )
        let trackURL = directory.appendingPathComponent(
            "track-observation.json"
        )
        let timingURL = directory.appendingPathComponent(
            "timing-observation.json"
        )
        let pixelURL = directory.appendingPathComponent(
            "pixel-observation.json"
        )
        let attachmentURL = directory.appendingPathComponent(
            "attachment-observation.json"
        )
        try MirmirPackagedMediaJSONV4.write(tracks, to: trackURL)
        try MirmirPackagedMediaJSONV4.write(timing, to: timingURL)
        try MirmirPackagedMediaJSONV4.write(pixelResult.observation, to: pixelURL)
        try MirmirPackagedMediaJSONV4.write(attachments, to: attachmentURL)
        return SideCapture(
            enabledTrackCount: tracks["enabledTrackCount"] as! Int,
            descriptors: [
                "media": try artifact(mediaURL, root: directory
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()),
                "trackObservation": try artifact(trackURL, root: directory
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()),
                "timingObservation": try artifact(timingURL, root: directory
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()),
                "pixels": try artifact(pixelResult.url, root: directory
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()),
                "pixelObservation": try artifact(pixelURL, root: directory
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()),
                "attachmentObservation": try artifact(
                    attachmentURL,
                    root: directory.deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                )
            ],
            pixelObservation: pixelResult.observation
        )
    }

    static func pixelIdentities(at mediaURL: URL) async throws -> [Int: String] {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-m7-repeat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = AVURLAsset(url: mediaURL)
        return try await pixelObservation(
            fixtureID: "repeat",
            side: "output",
            asset: asset,
            directory: temporary,
            repeatVisibleSHA256: [:],
            preEncodeAlphaFrameSHA256: [:],
            repeatPreEncodeAlphaFrameSHA256: [:]
        ).identities
    }

    static func visibleIdentities(_ observation: [String: Any]) -> [Int: String] {
        guard let tracks = observation["tracks"] as? [[String: Any]] else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
            guard let ordinal = track["ordinal"] as? Int,
                  let identity = track["visibleSHA256"] as? String else {
                return nil
            }
            return (ordinal, identity)
        })
    }

    private static func metadataIdentities(
        for asset: AVAsset
    ) async throws -> MetadataIdentities {
        let metadata = try await asset.load(.metadata)
        let assetItems = try await canonicalMetadataRows(metadata)
        let locales = try await asset.load(.availableChapterLocales)
            .sorted { $0.identifier < $1.identifier }
        var chapterRows: [[String: Any]] = []
        for locale in locales {
            let groups = try await asset.loadChapterMetadataGroups(
                withTitleLocale: locale
            )
            for (ordinal, group) in groups.enumerated() {
                chapterRows.append([
                    "localeID": locale.identifier,
                    "ordinal": ordinal,
                    "start": rationalOrInvalid(group.timeRange.start),
                    "duration": rationalOrInvalid(group.timeRange.duration),
                    "items": try await canonicalMetadataRows(group.items)
                ])
            }
        }
        return MetadataIdentities(
            asset: try MirmirPackagedMediaJSONV4.hash([
                "items": assetItems
            ]),
            chapter: try MirmirPackagedMediaJSONV4.hash([
                "groups": chapterRows
            ])
        )
    }

    private static func canonicalMetadataRows(
        _ items: [AVMetadataItem]
    ) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for item in items {
            let value = try await item.load(.value)
            rows.append([
                "identifier": item.identifier?.rawValue ?? NSNull(),
                "keySpace": item.keySpace?.rawValue ?? NSNull(),
                "commonKey": item.commonKey?.rawValue ?? NSNull(),
                "key": try metadataJSONValue(item.key),
                "extendedLanguageTag": item.extendedLanguageTag ?? NSNull(),
                "localeID": item.locale?.identifier ?? NSNull(),
                "startDateBitPattern": item.startDate.map {
                    String($0.timeIntervalSinceReferenceDate.bitPattern)
                } ?? NSNull(),
                "dataType": item.dataType ?? NSNull(),
                "time": rationalOrInvalid(item.time),
                "duration": rationalOrInvalid(item.duration),
                "value": try metadataJSONValue(value)
            ])
        }
        return try rows.sorted {
            try MirmirPackagedMediaJSONV4.hash($0)
                < MirmirPackagedMediaJSONV4.hash($1)
        }
    }

    private static func metadataJSONValue(_ value: Any?) throws -> Any {
        guard let value else { return NSNull() }
        if value is NSNull { return NSNull() }
        if let string = value as? String {
            return ["type": "string", "value": string]
        }
        if let data = value as? Data {
            return [
                "type": "data",
                "byteCount": data.count,
                "sha256": ASHSHA256V4(rawData: data).rawValue
            ]
        }
        if let date = value as? Date {
            return [
                "type": "date",
                "bitPattern": String(
                    date.timeIntervalSinceReferenceDate.bitPattern
                )
            ]
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return ["type": "boolean", "value": number.boolValue]
            }
            return [
                "type": "number",
                "objcType": String(cString: number.objCType),
                "value": number.stringValue
            ]
        }
        if let url = value as? URL {
            return ["type": "url", "value": url.absoluteString]
        }
        if let array = value as? NSArray {
            return [
                "type": "array",
                "value": try array.map(metadataJSONValue)
            ]
        }
        if let dictionary = value as? NSDictionary {
            var entries = try dictionary.map { key, item in
                [
                    "key": try metadataJSONValue(key),
                    "value": try metadataJSONValue(item)
                ]
            }
            entries = try entries.sorted {
                try MirmirPackagedMediaJSONV4.hash($0)
                    < MirmirPackagedMediaJSONV4.hash($1)
            }
            return ["type": "object", "value": entries]
        }
        throw MirmirPackagedMediaErrorV4.invalid(
            "unsupported AVMetadataItem value"
        )
    }

    private static func trackObservation(
        fixtureID: String,
        side: String,
        graph: MediaTrackGraphV4,
        metadata: MetadataIdentities?
    ) throws -> [String: Any] {
        let ordinalByID = Dictionary(
            uniqueKeysWithValues: graph.tracks.map {
                ($0.identity.stableID, Int($0.identity.ordinal))
            }
        )
        let tracks: [[String: Any]] = try graph.tracks.map { track in
            [
                "ordinal": Int(track.identity.ordinal),
                "stableID": track.identity.stableID.rawValue,
                "kind": track.kind.rawValue,
                "enabled": track.enabled,
                "mediaTypeID": track.sourceMediaTypeID,
                "codecID": track.formatDescriptors.first?.mediaSubtypeID
                    ?? "unknown",
                "languageCode": track.language.languageCode ?? NSNull(),
                "extendedLanguageTag": track.language.extendedLanguageTag
                    ?? NSNull(),
                "roleIDs": track.roleIDs,
                "timebase": track.timebase.description,
                "timeRangeSHA256": try encodableHash(track.timeRange),
                "editsSHA256": try encodableHash(track.edits),
                "formatSHA256": try encodableHash(track.formatDescriptors),
                "metadataSHA256": track.metadataFingerprint.rawValue
            ]
        }
        let groups: [[String: Any]] = graph.groups.map { group in
            [
                "ordinal": Int(group.identity.ordinal),
                "kind": group.kind.rawValue,
                "memberOrdinals": group.memberTrackIDs.compactMap {
                    ordinalByID[$0]
                },
                "defaultOrdinal": group.defaultTrackID.flatMap {
                    ordinalByID[$0]
                } ?? NSNull(),
                "allowsEmptySelection": group.allowsEmptySelection
            ]
        }
        let associations: [[String: Any]] = graph.associations.map {
            association in
            [
                "ordinal": Int(association.ordinal),
                "sourceOrdinal": ordinalByID[
                    association.sourceTrackID
                ]!,
                "targetOrdinal": ordinalByID[
                    association.targetTrackID
                ]!,
                "kind": association.kind.rawValue
            ]
        }
        let empty = ASHSHA256V4(rawData: Data()).rawValue
        return [
            "schemaVersion": "mirmir-ash-v4-track-observation-v2",
            "fixtureID": fixtureID,
            "side": side,
            "enabledTrackCount": graph.tracks.filter(\.enabled).count,
            "tracks": tracks,
            "groups": groups,
            "associations": associations,
            "assetMetadataSHA256": metadata?.asset ?? empty,
            "chapterMetadataSHA256": metadata?.chapter ?? empty
        ]
    }

    private static func timingObservation(
        fixtureID: String,
        side: String,
        asset: AVAsset
    ) async throws -> [String: Any] {
        let assetTracks = try await asset.load(.tracks)
        var rows: [[String: Any]] = []
        for (ordinal, track) in assetTracks.enumerated() {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: nil
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw MirmirPackagedMediaErrorV4.reader
            }
            reader.add(output)
            guard reader.startReading() else {
                throw MirmirPackagedMediaErrorV4.reader
            }
            var samples: [[String: Any]] = []
            while let sample = output.copyNextSampleBuffer() {
                guard MirmirPackagedMediaTimingSampleV4.admits(sample) else {
                    continue
                }
                let payload = try encodedPayload(sample)
                samples.append([
                    "pts": rational(
                        CMSampleBufferGetPresentationTimeStamp(sample)
                    ),
                    "dts": rationalOrInvalid(
                        CMSampleBufferGetDecodeTimeStamp(sample)
                    ),
                    "duration": rational(
                        CMSampleBufferGetDuration(sample)
                    ),
                    "byteCount": payload.count,
                    "payloadSHA256": ASHSHA256V4(rawData: payload).rawValue
                ])
            }
            guard reader.status == .completed else {
                throw MirmirPackagedMediaErrorV4.reader
            }
            let timings = samples.map { sample in
                [
                    "pts": sample["pts"]!,
                    "dts": sample["dts"]!,
                    "duration": sample["duration"]!
                ]
            }
            rows.append([
                "ordinal": ordinal,
                "sampleCount": samples.count,
                "timingSHA256": try MirmirPackagedMediaJSONV4.hash(timings),
                "encodedPayloadSHA256": try MirmirPackagedMediaJSONV4.hash(
                    samples.map { $0["payloadSHA256"]! }
                ),
                "samples": samples
            ])
        }
        return [
            "schemaVersion": "mirmir-ash-v4-timing-observation-v1",
            "fixtureID": fixtureID,
            "side": side,
            "tracks": rows
        ]
    }

    private struct PixelResult {
        let url: URL
        let observation: [String: Any]
        let identities: [Int: String]
    }

    private static func pixelObservation(
        fixtureID: String,
        side: String,
        asset: AVAsset,
        directory: URL,
        repeatVisibleSHA256: [Int: String],
        preEncodeAlphaFrameSHA256: [Int: [String]],
        repeatPreEncodeAlphaFrameSHA256: [Int: [String]]
    ) async throws -> PixelResult {
        let graph = try await AVFoundationTrackGraphAdapterV4.probe(asset: asset)
        let canonical = try await AVCanonicalMediaStateAdapterV4().probe(
            .init(
                url: (asset as! AVURLAsset).url,
                bookmarkReference: "m7-media-capture",
                bookmarkDocumentSHA256: ASHSHA256V4(
                    rawData: Data("m7-media-capture-bookmark".utf8)
                ),
                scanDynamicHDRMetadata: true
            )
        ).requireAdmittedState()
        var artifact = Data()
        var rows: [[String: Any]] = []
        var identities: [Int: String] = [:]
        let tracks = try await asset.load(.tracks)
        for (ordinal, track) in tracks.enumerated() {
            guard graph.tracks[ordinal].kind == .video else { continue }
            let canonicalVideo = canonical.tracks[ordinal].video!
            let pixelFormat: OSType = canonicalVideo.pixel.alphaModel == .none
                ? (canonicalVideo.pixel.bitDepth == 10
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    : kCVPixelFormatType_32BGRA)
                : kCVPixelFormatType_32BGRA
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
                ]
            )
            output.alwaysCopiesSampleData = true
            guard reader.canAdd(output) else {
                throw MirmirPackagedMediaErrorV4.reader
            }
            reader.add(output)
            guard reader.startReading() else {
                throw MirmirPackagedMediaErrorV4.reader
            }
            var visible = Data()
            var alpha = Data()
            var alphaFrameSHA256: [String] = []
            var codes = Set<UInt16>()
            var lowPaddingViolations = 0
            var frameCount = 0
            var width = 0
            var height = 0
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                    throw MirmirPackagedMediaErrorV4.reader
                }
                width = CVPixelBufferGetWidth(buffer)
                height = CVPixelBufferGetHeight(buffer)
                let bytes = try visibleBytes(buffer)
                visible.append(bytes)
                artifact.append(bytes)
                if canonicalVideo.pixel.alphaModel != .none {
                    let alphaFrame = try Alpha4444PixelBufferAccessV4
                        .alphaPlaneBytes(buffer, layout: .bgra8)
                    alpha.append(alphaFrame)
                    alphaFrameSHA256.append(
                        ASHSHA256V4(rawData: alphaFrame).rawValue
                    )
                }
                if canonicalVideo.pixel.bitDepth == 10 {
                    try collectP010(
                        buffer,
                        codes: &codes,
                        lowPaddingViolations: &lowPaddingViolations
                    )
                }
                frameCount += 1
            }
            guard reader.status == .completed else {
                throw MirmirPackagedMediaErrorV4.reader
            }
            let visibleSHA = ASHSHA256V4(rawData: visible).rawValue
            let alphaSHA = alpha.isEmpty
                ? nil : ASHSHA256V4(rawData: alpha).rawValue
            identities[ordinal] = visibleSHA
            let preEncode = preEncodeAlphaFrameSHA256[ordinal] ?? []
            let repeatPreEncode = repeatPreEncodeAlphaFrameSHA256[ordinal]
                ?? []
            rows.append([
                "ordinal": ordinal,
                "kind": "video",
                "pixelFormat": fourCC(pixelFormat),
                "bitDepth": Int(canonicalVideo.pixel.bitDepth),
                "width": width,
                "height": height,
                "frameCount": frameCount,
                "visibleSHA256": visibleSHA,
                "repeatVisibleSHA256": repeatVisibleSHA256[ordinal]
                    ?? visibleSHA,
                "alphaSHA256": alphaSHA ?? NSNull(),
                "alphaFrameSHA256": alphaFrameSHA256,
                "preEncodeAlphaFrameSHA256": preEncode,
                "repeatPreEncodeAlphaFrameSHA256": repeatPreEncode,
                "decodedAlphaSHA256": alphaSHA ?? NSNull(),
                "uniqueSignalCodeCount": canonicalVideo.pixel.bitDepth == 10
                    ? codes.count : 0,
                "lowPaddingBitViolationCount": lowPaddingViolations
            ])
        }
        let artifactURL = directory.appendingPathComponent("pixels.bin")
        try artifact.write(to: artifactURL, options: .atomic)
        return PixelResult(
            url: artifactURL,
            observation: [
                "schemaVersion": "mirmir-ash-v4-pixel-observation-v2",
                "fixtureID": fixtureID,
                "side": side,
                "pixelArtifactSHA256": ASHSHA256V4(
                    rawData: artifact
                ).rawValue,
                "pixelArtifactByteCount": artifact.count,
                "tracks": rows
            ],
            identities: identities
        )
    }

    private static func attachmentObservation(
        fixtureID: String,
        side: String,
        mediaURL: URL,
        asset: AVAsset
    ) async throws -> [String: Any] {
        let canonical = try await AVCanonicalMediaStateAdapterV4().probe(
            .init(
                url: mediaURL,
                bookmarkReference: "m7-media-attachments",
                bookmarkDocumentSHA256: ASHSHA256V4(
                    rawData: Data("m7-media-attachments-bookmark".utf8)
                ),
                scanDynamicHDRMetadata: true
            )
        ).requireAdmittedState()
        let tracks = try await asset.load(.tracks)
        var rows: [[String: Any]] = []
        for (ordinal, canonicalTrack) in canonical.tracks.enumerated() {
            guard let video = canonicalTrack.video else { continue }
            let dynamic = try await dynamicMetadata(
                asset: asset,
                track: tracks[ordinal],
                pixelFormat: video.pixel.bitDepth == 10
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    : kCVPixelFormatType_32BGRA
            )
            let ambientViewingEnvironment = try await
                ambientViewingEnvironmentPayload(track: tracks[ordinal])
            let clean: CanonicalRationalRectV4
            if let cleanAperture = video.cleanAperture {
                clean = cleanAperture
            } else {
                clean = CanonicalRationalRectV4(
                    origin: CanonicalRationalPointV4(x: .zero, y: .zero),
                    size: CanonicalRationalSizeV4(
                        width: try ExactRationalV4(video.encodedRaster.width),
                        height: try ExactRationalV4(video.encodedRaster.height)
                    )
                )
            }
            let detail: String
            let cadence: String
            switch video.scan.dominance {
            case .topFieldFirst:
                detail = "temporal_top_first"
                cadence = "interlaced_tff_2_fields_per_sample"
            case .bottomFieldFirst:
                detail = "temporal_bottom_first"
                cadence = "interlaced_bff_2_fields_per_sample"
            case .none:
                detail = "progressive"
                cadence = side == "output" && fixtureID
                    == "combined-p010-hdr-interlaced"
                    ? "progressive_double_rate" : "progressive"
            case .unknown:
                detail = "unknown"
                cadence = "unknown"
            }
            rows.append([
                "ordinal": ordinal,
                "kind": "video",
                "fieldCount": Int(video.scan.fieldCount),
                "fieldDetail": detail,
                "cadence": cadence,
                "pixelAspectRatio": [
                    "horizontal": Int(video.pixelAspectRatio.numerator),
                    "vertical": Int(video.pixelAspectRatio.denominator)
                ],
                "cleanAperture": [
                    "width": clean.size.width.description,
                    "height": clean.size.height.description,
                    "horizontalOffset": clean.origin.x.description,
                    "verticalOffset": clean.origin.y.description
                ],
                "preferredTransform": [
                    video.preferredTransform.a.description,
                    video.preferredTransform.b.description,
                    video.preferredTransform.c.description,
                    video.preferredTransform.d.description,
                    video.preferredTransform.tx.description,
                    video.preferredTransform.ty.description
                ],
                "colorPrimaries": video.color.primaries,
                "transferFunction": video.color.transferFunction,
                "yCbCrMatrix": video.color.matrix,
                "masteringDisplaySHA256": try video.color.masteringDisplay
                    .map(encodableHash) ?? NSNull(),
                "contentLightSHA256": try video.color.contentLightLevel
                    .map(encodableHash) ?? NSNull(),
                "ambientViewingEnvironmentSHA256":
                    ambientViewingEnvironment.map {
                        ASHSHA256V4(rawData: $0).rawValue
                    } ?? NSNull(),
                "dynamicHDRSamples": dynamic,
                "alphaAssociation": video.pixel.alphaModel == .none
                    ? NSNull() : video.pixel.alphaModel.rawValue
            ])
        }
        return [
            "schemaVersion": "mirmir-ash-v4-attachment-observation-v1",
            "fixtureID": fixtureID,
            "side": side,
            "tracks": rows
        ]
    }

    private static func ambientViewingEnvironmentPayload(
        track: AVAssetTrack
    ) async throws -> Data? {
        let descriptions = try await track.load(.formatDescriptions)
        var identity: Data?
        for description in descriptions {
            guard let rawExtensions =
                CMFormatDescriptionGetExtensions(description) else {
                continue
            }
            let extensions = rawExtensions as NSDictionary
            guard let raw = extensions[
                kCMFormatDescriptionExtension_AmbientViewingEnvironment
                    as String
            ] else { continue }
            guard let payload = raw as? Data else {
                throw MirmirPackagedMediaErrorV4.invalid(
                    "ambient viewing environment is not CFData"
                )
            }
            _ = try AmbientViewingEnvironmentV4(payload: payload)
            if let identity, identity != payload {
                throw MirmirPackagedMediaErrorV4.invalid(
                    "ambient viewing environment differs across formats"
                )
            }
            identity = payload
        }
        return identity
    }

    private static func dynamicMetadata(
        asset: AVAsset,
        track: AVAssetTrack,
        pixelFormat: OSType
    ) async throws -> [[String: Any]] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
            ]
        )
        guard reader.canAdd(output) else { throw MirmirPackagedMediaErrorV4.reader }
        reader.add(output)
        guard reader.startReading() else { throw MirmirPackagedMediaErrorV4.reader }
        var result: [[String: Any]] = []
        var ordinal = 0
        while let sample = output.copyNextSampleBuffer() {
            if let value = try AVFoundationHDRMetadataAdapterV4
                .probeDynamicMetadata(from: sample) {
                result.append([
                    "sampleOrdinal": ordinal,
                    "pts": rational(
                        CMSampleBufferGetPresentationTimeStamp(sample)
                    ),
                    "hdr10PlusSHA256": value.hdr10Plus.map {
                        ASHSHA256V4(rawData: $0.ituTT35Payload).rawValue
                    } ?? NSNull(),
                    "postDecodeSHA256": value.postDecodeProcessing.map {
                        ASHSHA256V4(
                            rawData: $0.binaryPropertyList
                        ).rawValue
                    } ?? NSNull()
                ])
            }
            ordinal += 1
        }
        guard reader.status == .completed else {
            throw MirmirPackagedMediaErrorV4.reader
        }
        return result
    }

    static func artifact(_ url: URL, root: URL) throws
        -> [String: Any] {
        let data = try Data(contentsOf: url)
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw MirmirPackagedMediaErrorV4.invalid("artifact path")
        }
        return [
            "path": String(filePath.dropFirst(rootPath.count + 1)),
            "byteCount": data.count,
            "sha256": ASHSHA256V4(rawData: data).rawValue
        ]
    }

    private static func encodableHash<T: Encodable>(_ value: T) throws
        -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ASHSHA256V4(rawData: try encoder.encode(value)).rawValue
    }

    private static func encodedPayload(_ sample: CMSampleBuffer) throws
        -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            if let image = CMSampleBufferGetImageBuffer(sample) {
                return try visibleBytes(image)
            }
            return Data()
        }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: length,
                destination: bytes.baseAddress!
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw MirmirPackagedMediaErrorV4.coreMedia(status)
        }
        return data
    }

    private static func visibleBytes(_ buffer: CVPixelBuffer) throws -> Data {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw MirmirPackagedMediaErrorV4.coreVideo(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var result = Data()
        let planeCount = CVPixelBufferIsPlanar(buffer)
            ? CVPixelBufferGetPlaneCount(buffer) : 1
        for plane in 0..<planeCount {
            let base: UnsafeMutableRawPointer?
            let height: Int
            let activeBytes: Int
            let rowBytes: Int
            if CVPixelBufferIsPlanar(buffer) {
                base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
                height = CVPixelBufferGetHeightOfPlane(buffer, plane)
                let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
                activeBytes = width * (plane == 0 ? 2 : 4)
                rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            } else {
                base = CVPixelBufferGetBaseAddress(buffer)
                height = CVPixelBufferGetHeight(buffer)
                activeBytes = CVPixelBufferGetWidth(buffer) * 4
                rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            }
            guard let base else { throw MirmirPackagedMediaErrorV4.reader }
            for y in 0..<height {
                result.append(
                    base.advanced(by: y * rowBytes)
                        .assumingMemoryBound(to: UInt8.self),
                    count: activeBytes
                )
            }
        }
        return result
    }

    private static func collectP010(
        _ buffer: CVPixelBuffer,
        codes: inout Set<UInt16>,
        lowPaddingViolations: inout Int
    ) throws {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw MirmirPackagedMediaErrorV4.coreVideo(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        for plane in 0..<2 {
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
            let components = width * (plane == 0 ? 1 : 2)
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)?
                .assumingMemoryBound(to: UInt16.self) else {
                throw MirmirPackagedMediaErrorV4.reader
            }
            for y in 0..<height {
                for x in 0..<components {
                    let word = base[y * stride + x]
                    if word & 0x003F != 0 { lowPaddingViolations += 1 }
                    codes.insert(word >> 6)
                }
            }
        }
    }

    private static func rationalOrInvalid(_ time: CMTime) -> String {
        time.isNumeric ? rational(time) : "invalid"
    }

    private static func rational(_ time: CMTime) -> String {
        precondition(time.isNumeric && time.timescale > 0)
        var numerator = time.value
        var denominator = Int64(time.timescale)
        let divisor = gcd(abs(numerator), denominator)
        numerator /= divisor
        denominator /= divisor
        return denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)"
    }

    private static func gcd(_ first: Int64, _ second: Int64) -> Int64 {
        var left = first
        var right = second
        while right != 0 {
            (left, right) = (right, left % right)
        }
        return max(left, 1)
    }

    private static func fourCC(_ value: OSType) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .macOSRoman)
            ?? String(format: "%08x", value)
    }
}

// MARK: - Notarized release qualification observer

/// The release observer is reachable only through one exact command-line
/// envelope. Normal launches never instantiate it. Keeping this entry point in
/// the shipping target lets the release harness prove behavior of the exact
/// archived executable instead of a test bundle or helper process.
enum MirmirNotarizedSmokeInvocationV4 {
    static let flag = "--mirmir-v4-notarized-smoke"

    static var wasRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.count == 3 && arguments[1] == flag
    }

    fileprivate static func parse() throws -> MirmirNotarizedSmokeRequestV4 {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.count == 3,
              arguments[1] == flag,
              let bytes = Data(base64Encoded: arguments[2]),
              !bytes.isEmpty else {
            throw MirmirNotarizedSmokeErrorV4.invalidInvocation
        }
        let request: MirmirNotarizedSmokeRequestV4
        do {
            request = try JSONDecoder().decode(
                MirmirNotarizedSmokeRequestV4.self,
                from: bytes
            )
        } catch {
            throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                "the command envelope is not canonical request JSON"
            )
        }
        let canonical = try MirmirNotarizedSmokeFilesV4.canonicalData(request)
        guard canonical == bytes else {
            throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                "the command envelope contains unknown, duplicate, or noncanonical fields"
            )
        }
        try request.validate()
        return request
    }
}

@MainActor
final class MirmirApplicationDelegate: NSObject, NSApplicationDelegate {
    private var qualificationTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard MirmirNotarizedSmokeInvocationV4.wasRequested
                || MirmirPackagedEvidenceInvocationV4.wasRequested else {
            return
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if MirmirPackagedEvidenceInvocationV4.wasRequested {
            qualificationTask = Task.detached(priority: .userInitiated) {
                await MirmirPackagedEvidenceObserverV4.runAndExit()
            }
            return
        }
        guard MirmirNotarizedSmokeInvocationV4.wasRequested else { return }
        qualificationTask = Task.detached(priority: .userInitiated) {
            do {
                let request = try MirmirNotarizedSmokeInvocationV4.parse()
                let result = try await MirmirNotarizedSmokeObserverV4.run(
                    request
                )
                MirmirNotarizedSmokeObserverV4.emit(
                    prefix: "MIRMIR_V4_NOTARIZED_SMOKE_RESULT ",
                    data: result
                )
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                let result = MirmirNotarizedSmokeObserverV4.errorEnvelope(error)
                MirmirNotarizedSmokeObserverV4.emit(
                    prefix: "MIRMIR_V4_NOTARIZED_SMOKE_ERROR ",
                    data: result
                )
                Darwin.exit(70)
            }
        }
    }
}

private enum MirmirNotarizedSmokePhaseV4: String, Codable, Sendable {
    case prepare
    case recover
}

private struct MirmirNotarizedSmokeRequestV4: Codable, Sendable {
    static let schema = "mirmir-ash-v4-notarized-smoke-request-v1"

    let schemaVersion: String
    let phase: MirmirNotarizedSmokePhaseV4
    let requestID: String
    let nonce: String
    let generatedAtUTC: String
    let laneContractSHA256: String
    let releaseContractSHA256: String
    let applicationArchiveSHA256: String
    let sourceCommit: String
    let bundleIdentifier: String
    let productVersion: String
    let productBuild: String
    let runtimeManifestSHA256: String
    let runtimeManifestFileSHA256: String
    let expectedExecutableSHA256: String
    let phaseOneResultSHA256: String?

    func validate() throws {
        guard schemaVersion == Self.schema else {
            throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                "unsupported request schema"
            )
        }
        guard let uuid = UUID(uuidString: requestID),
              uuid.uuidString.lowercased() == requestID else {
            throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                "requestID must be a canonical lowercase UUID"
            )
        }
        for (label, value, lengths) in [
            ("nonce", nonce, [64]),
            ("laneContractSHA256", laneContractSHA256, [64]),
            ("releaseContractSHA256", releaseContractSHA256, [64]),
            ("applicationArchiveSHA256", applicationArchiveSHA256, [64]),
            ("sourceCommit", sourceCommit, [40]),
            ("runtimeManifestSHA256", runtimeManifestSHA256, [64]),
            ("runtimeManifestFileSHA256", runtimeManifestFileSHA256, [64]),
            ("expectedExecutableSHA256", expectedExecutableSHA256, [64])
        ] {
            guard lengths.contains(value.utf8.count),
                  MirmirNotarizedSmokeFilesV4.isLowercaseHex(value) else {
                throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                    "\(label) is not a lowercase hexadecimal identity"
                )
            }
        }
        guard !bundleIdentifier.isEmpty,
              !productVersion.isEmpty,
              !productBuild.isEmpty,
              bundleIdentifier.utf8.count <= 255,
              productVersion.utf8.count <= 255,
              productBuild.utf8.count <= 255 else {
            throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                "bundle identity is missing or oversized"
            )
        }
        switch phase {
        case .prepare:
            guard phaseOneResultSHA256 == nil else {
                throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                    "prepare cannot bind a phase-one result"
                )
            }
        case .recover:
            guard let phaseOneResultSHA256,
                  phaseOneResultSHA256.utf8.count == 64,
                  MirmirNotarizedSmokeFilesV4.isLowercaseHex(
                    phaseOneResultSHA256
                  ) else {
                throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                    "recover requires the exact phase-one result identity"
                )
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let generated = formatter.date(from: generatedAtUTC) else {
            throw MirmirNotarizedSmokeErrorV4.invalidRequest(
                "generatedAtUTC is not canonical UTC"
            )
        }
        let age = Date().timeIntervalSince(generated)
        guard age >= -30, age <= 300 else {
            throw MirmirNotarizedSmokeErrorV4.staleRequest
        }
    }
}

private enum MirmirNotarizedSmokeErrorV4: Error, LocalizedError {
    case invalidInvocation
    case invalidRequest(String)
    case staleRequest
    case identityMismatch(String)
    case unsafeQualificationRoot(String)
    case invariant(String)

    var errorDescription: String? {
        switch self {
        case .invalidInvocation:
            "The notarized qualification invocation is malformed."
        case .invalidRequest(let reason):
            "The notarized qualification request is invalid: \(reason)"
        case .staleRequest:
            "The notarized qualification request is stale or future-dated."
        case .identityMismatch(let reason):
            "The notarized candidate identity does not match: \(reason)"
        case .unsafeQualificationRoot(let path):
            "The qualification sandbox root is unsafe: \(path)"
        case .invariant(let reason):
            "The notarized qualification invariant failed: \(reason)"
        }
    }
}

private struct MirmirSmokeArtifactV4: Codable, Equatable, Sendable {
    let path: String
    let byteCount: Int
    let sha256: String
}

private struct MirmirSmokeProcessIdentityV4: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let productVersion: String
    let productBuild: String
    let bundlePath: String
    let executablePath: String
    let executableSHA256: String
    let processID: Int32
    let parentProcessID: Int32
    let sandboxDataPath: String
    let applicationSupportPath: String
    let qualificationRootPath: String
}

private struct MirmirSmokeRuntimeIdentityV4: Codable, Equatable, Sendable {
    let runtimeID: String
    let releaseStatus: String
    let manifestSHA256: String
    let manifestFileSHA256: String
    let sourceRevision: String
    let builderSourceSHA256: String
    let artifactCount: Int
    let runtimeBundlePath: String
    let trustRootConfigured: Bool
}

private struct MirmirSmokeProbeIdentityV4: Codable, Equatable, Sendable {
    let encodedWidth: Int
    let encodedHeight: Int
    let codecFourCC: String
    let durationValue: Int64
    let durationTimescale: Int32
    let estimatedFrameCount: Int
    let videoTrackCount: Int
    let audioTrackCount: Int
    let bitDepth: Int
    let bitDepthEvidence: String
    let isFullRange: Bool
    let rangeEvidence: String
    let dynamicRange: String
    let fieldCount: Int
    let fieldCountEvidence: String
    let readable: Bool
    let playable: Bool
}

private struct MirmirSmokeSemanticIdentityV4: Codable, Equatable, Sendable {
    let encodedWidth: Int
    let encodedHeight: Int
    let frameCount: Int
    let enabledVideoTrackCount: Int
    let durationValue: Int64
    let durationTimescale: Int32
    let timingSHA256: String
    let visiblePixelSHA256: String
}

private struct MirmirSmokeProcessingIdentityV4: Codable, Equatable, Sendable {
    let actualBackendID: String
    let processedFrameCount: Int
    let encodedWidth: Int
    let encodedHeight: Int
    let outputCodec: String
    let processingDurationSeconds: Double
}

private struct MirmirSmokePhaseOneStateV4: Codable, Equatable, Sendable {
    static let schema = "mirmir-ash-v4-notarized-smoke-phase-one-state-v1"

    let schemaVersion: String
    let requestID: String
    let nonceSHA256: String
    let requestSHA256: String
    let applicationArchiveSHA256: String
    let sourceCommit: String
    let executableSHA256: String
    let runtimeManifestSHA256: String
    let runtimeManifestFileSHA256: String
    let jobID: String
    let inputArtifact: MirmirSmokeArtifactV4
    let inputSemantic: MirmirSmokeSemanticIdentityV4
    let directOutputArtifact: MirmirSmokeArtifactV4
    let directOutputSemantic: MirmirSmokeSemanticIdentityV4
    let queueTreeSHA256: String
}

private enum MirmirNotarizedSmokeFilesV4 {
    static let namespace = "MirmirQualificationV4/notarized-smoke"
    static let maximumTreeBytes = 512 * 1_024 * 1_024

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func canonicalData(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "attempted to publish invalid JSON"
            )
        }
        return try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(
            with: canonicalData(value),
            options: [.fragmentsAllowed]
        )
    }

    static func isLowercaseHex(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    static func hex<D: Sequence>(_ digest: D) -> String
    where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let bytes = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !bytes.isEmpty else { break }
            digest.update(data: bytes)
        }
        return hex(digest.finalize())
    }

    static func writeNew(_ data: Data, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "refusing to overwrite \(url.lastPathComponent)"
            )
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).partial"
        )
        var descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot create atomic evidence temporary: \(posixError())"
            )
        }
        var removeTemporary = true
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if removeTemporary { _ = Darwin.unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let address = bytes.baseAddress else {
                    throw MirmirNotarizedSmokeErrorV4.invariant(
                        "atomic evidence bytes have no base address"
                    )
                }
                let written = Darwin.write(
                    descriptor,
                    address.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw MirmirNotarizedSmokeErrorV4.invariant(
                        "cannot write atomic evidence: \(posixError())"
                    )
                }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot synchronize atomic evidence: \(posixError())"
            )
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot close atomic evidence: \(posixError())"
            )
        }
        descriptor = -1
        // link(2) publishes the fully synchronized bytes atomically and fails
        // rather than replacing a concurrently created destination.
        guard Darwin.link(temporary.path, url.path) == 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot publish atomic evidence: \(posixError())"
            )
        }
        guard Darwin.unlink(temporary.path) == 0 else {
            _ = Darwin.unlink(url.path)
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot retire atomic evidence temporary: \(posixError())"
            )
        }
        removeTemporary = false
        let directory = url.deletingLastPathComponent()
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else {
            _ = Darwin.unlink(url.path)
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot open evidence directory for synchronization: "
                    + posixError()
            )
        }
        defer { _ = Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            _ = Darwin.unlink(url.path)
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot synchronize evidence directory: \(posixError())"
            )
        }
    }

    static func posixError() -> String {
        String(cString: strerror(errno))
    }

    static func writeNew<T: Encodable>(_ value: T, to url: URL) throws {
        try writeNew(canonicalData(value), to: url)
    }

    static func decodeCanonical<T: Codable>(
        _ type: T.Type,
        from url: URL
    ) throws -> T {
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder().decode(type, from: data)
        guard try canonicalData(value) == data else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "\(url.lastPathComponent) is noncanonical"
            )
        }
        return value
    }

    static func artifact(root: URL, url: URL) throws -> MirmirSmokeArtifactV4 {
        let root = root.standardizedFileURL
        let file = url.standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "artifact escapes qualification root"
            )
        }
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= maximumTreeBytes else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "artifact is not a bounded regular file"
            )
        }
        let relative = String(file.path.dropFirst(root.path.count + 1))
        return MirmirSmokeArtifactV4(
            path: relative,
            byteCount: Int(metadata.st_size),
            sha256: try sha256(file)
        )
    }

    static func treeSHA256(_ root: URL) throws -> String {
        let root = root.standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "tree root is missing"
            )
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot enumerate qualification tree"
            )
        }
        let urls = (enumerator.allObjects as? [URL] ?? []).sorted {
            $0.path < $1.path
        }
        if let enumerationError {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "qualification tree enumeration failed: "
                    + enumerationError.localizedDescription
            )
        }
        var totalBytes = 0
        var digest = SHA256()
        digest.update(data: Data("mirmir-notarized-smoke-tree-v1\0".utf8))
        for url in urls {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw MirmirNotarizedSmokeErrorV4.invariant(
                    "tree entry vanished during sealing"
                )
            }
            digest.update(data: Data(relative.utf8))
            digest.update(data: Data([0]))
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                digest.update(data: Data("directory\n".utf8))
            case S_IFREG:
                guard metadata.st_nlink == 1, metadata.st_size >= 0 else {
                    throw MirmirNotarizedSmokeErrorV4.invariant(
                        "tree contains an unsafe regular file"
                    )
                }
                totalBytes += Int(metadata.st_size)
                guard totalBytes <= maximumTreeBytes else {
                    throw MirmirNotarizedSmokeErrorV4.invariant(
                        "qualification tree exceeds its byte bound"
                    )
                }
                digest.update(data: Data("file\0".utf8))
                digest.update(data: Data(try sha256(url).utf8))
                digest.update(data: Data("\n".utf8))
            default:
                throw MirmirNotarizedSmokeErrorV4.invariant(
                    "qualification tree contains a link or special file"
                )
            }
        }
        return hex(digest.finalize())
    }
}

private enum MirmirNotarizedSmokeObserverV4 {
    static let resultSchema =
        "mirmir-ash-v4-notarized-smoke-observer-result-v1"

    struct QualificationContext: Sendable {
        let root: URL
        let applicationSupport: URL
        let sandboxData: URL
    }

    static func run(_ request: MirmirNotarizedSmokeRequestV4) async throws
        -> Data {
        switch request.phase {
        case .prepare:
            try await prepare(request)
        case .recover:
            try await recover(request)
        }
    }

    static func emit(prefix: String, data: Data) {
        let line = prefix + data.base64EncodedString() + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        try? FileHandle.standardOutput.synchronize()
    }

    static func errorEnvelope(_ error: Error) -> Data {
        let description: String
        if let localized = error as? LocalizedError,
           let value = localized.errorDescription {
            description = value
        } else {
            description = String(describing: error)
        }
        let envelope: [String: Any] = [
            "schemaVersion":
                "mirmir-ash-v4-notarized-smoke-observer-error-v1",
            "errorType": String(reflecting: type(of: error)),
            "message": description,
            "observedAtUTC": utcNow()
        ]
        return (try? MirmirNotarizedSmokeFilesV4.canonicalData(envelope))
            ?? Data("{\"schemaVersion\":\"mirmir-ash-v4-notarized-smoke-observer-error-v1\"}".utf8)
    }

    private static func prepare(
        _ request: MirmirNotarizedSmokeRequestV4
    ) async throws -> Data {
        let context = try qualificationContext(request: request, create: true)
        let requestData = try MirmirNotarizedSmokeFilesV4.canonicalData(request)
        try MirmirNotarizedSmokeFilesV4.writeNew(
            requestData,
            to: context.root.appendingPathComponent("prepare-request.json")
        )
        let process = try processIdentity(request: request, context: context)
        let runtime = try runtimeIdentity(request: request)

        let mediaDirectory = context.root.appendingPathComponent(
            "media",
            isDirectory: true
        )
        try makeSecureDirectory(mediaDirectory)
        let inputURL = mediaDirectory.appendingPathComponent("source.mov")
        try await makeSourceMovie(at: inputURL)
        let source = try await VideoProbe().probe(url: inputURL)
        let inputProbe = try probeIdentity(source)
        let inputSemantic = try await semanticIdentity(at: inputURL)
        try validateLockedInput(probe: inputProbe, semantic: inputSemantic)

        let directURL = mediaDirectory.appendingPathComponent(
            "uninterrupted.mov"
        )
        let directRequest = processingRequest(
            input: inputURL,
            output: directURL
        )
        let referenceQueueRoot = context.root.appendingPathComponent(
            "reference-workflow-queue-v4",
            isDirectory: true
        )
        let referenceCoordinator = try workflowCoordinator(
            queueRoot: referenceQueueRoot,
            worker: "reference-\(request.requestID.prefix(12))"
        )
        let referenceLaunch = try await referenceCoordinator.launch()
        guard referenceLaunch.queue.items.isEmpty,
              referenceLaunch.recovery.items.isEmpty else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the unique uninterrupted reference queue was not empty"
            )
        }
        let referenceOutcome = try await referenceCoordinator.submit(
            request: directRequest,
            progress: { _ in },
            snapshot: { _ in }
        )
        let directResult: UpscaleResult
        switch referenceOutcome {
        case .completed(let completion):
            directResult = completion.result
        case .paused:
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the uninterrupted reference queue unexpectedly paused"
            )
        }
        let referenceSnapshot = try await referenceCoordinator.queueSnapshot()
        guard referenceSnapshot.items.count == 1,
              referenceSnapshot.items[0].lifecycle == .completed else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the uninterrupted reference queue did not complete"
            )
        }
        let directProcessing = try processingIdentity(directResult)
        let directSemantic = try await semanticIdentity(at: directURL)
        guard directProcessing.actualBackendID
                == UpscaleBackendID.mirmirDeterministicCPU.rawValue,
              directProcessing.encodedWidth == 96,
              directProcessing.encodedHeight == 72,
              directSemantic.frameCount > 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the uninterrupted deterministic CPU route did not produce the locked raster"
            )
        }

        let queueRoot = context.root.appendingPathComponent(
            "workflow-queue-v4",
            isDirectory: true
        )
        let coordinator = try workflowCoordinator(
            queueRoot: queueRoot,
            worker: "prepare-\(request.requestID.prefix(12))"
        )
        let initialLaunch = try await coordinator.launch()
        guard initialLaunch.queue.items.isEmpty,
              initialLaunch.recovery.items.isEmpty else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the unique qualification queue was not empty"
            )
        }
        let queueOutputURL = mediaDirectory.appendingPathComponent(
            "recovered.mov"
        )
        let queuedRequest = processingRequest(
            input: inputURL,
            output: queueOutputURL
        )
        let submitTask = Task {
            try await coordinator.submit(
                request: queuedRequest,
                progress: { _ in },
                snapshot: { _ in }
            )
        }
        var pauseRequestAccepted = false
        for _ in 0..<12_000 {
            do {
                try await coordinator.requestPause()
                pauseRequestAccepted = true
                break
            } catch WorkflowApplicationControllerErrorV4.noActiveJob {
                // Submission performs a production probe and plan before its
                // coordinator publishes the active execution. Poll that
                // actor-owned boundary rather than racing a queued snapshot.
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch {
                submitTask.cancel()
                _ = await submitTask.result
                throw error
            }
        }
        guard pauseRequestAccepted else {
            submitTask.cancel()
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the production queue did not accept pause before timeout"
            )
        }
        let outcome = try await submitTask.value
        let pausedJobID: WorkflowJobID
        switch outcome {
        case .paused(let jobID, _):
            pausedJobID = jobID
        case .completed:
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the job completed without publishing a resumable boundary"
            )
        }
        let pausedSnapshot = try await coordinator.queueSnapshot()
        guard pausedSnapshot.items.count == 1,
              pausedSnapshot.items[0].jobID == pausedJobID,
              pausedSnapshot.items[0].lifecycle == .paused,
              !FileManager.default.fileExists(atPath: queueOutputURL.path)
        else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the queue did not retain one paused unpublished job"
            )
        }
        let checkpointRelatedFiles = try regularFileCount(
            root: queueRoot,
            pathContains: "checkpoint"
        )
        guard checkpointRelatedFiles > 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the paused job has no durable checkpoint artifacts"
            )
        }
        let queueTreeSHA256 = try MirmirNotarizedSmokeFilesV4.treeSHA256(
            queueRoot
        )
        let inputArtifact = try MirmirNotarizedSmokeFilesV4.artifact(
            root: context.root,
            url: inputURL
        )
        let directArtifact = try MirmirNotarizedSmokeFilesV4.artifact(
            root: context.root,
            url: directURL
        )
        let state = MirmirSmokePhaseOneStateV4(
            schemaVersion: MirmirSmokePhaseOneStateV4.schema,
            requestID: request.requestID,
            nonceSHA256: MirmirNotarizedSmokeFilesV4.sha256(
                Data(request.nonce.utf8)
            ),
            requestSHA256: MirmirNotarizedSmokeFilesV4.sha256(requestData),
            applicationArchiveSHA256: request.applicationArchiveSHA256,
            sourceCommit: request.sourceCommit,
            executableSHA256: process.executableSHA256,
            runtimeManifestSHA256: runtime.manifestSHA256,
            runtimeManifestFileSHA256: runtime.manifestFileSHA256,
            jobID: pausedJobID.rawValue,
            inputArtifact: inputArtifact,
            inputSemantic: inputSemantic,
            directOutputArtifact: directArtifact,
            directOutputSemantic: directSemantic,
            queueTreeSHA256: queueTreeSHA256
        )
        let stateURL = context.root.appendingPathComponent(
            "phase-one-state.json"
        )
        try MirmirNotarizedSmokeFilesV4.writeNew(state, to: stateURL)
        let stateArtifact = try MirmirNotarizedSmokeFilesV4.artifact(
            root: context.root,
            url: stateURL
        )
        let result: [String: Any] = [
            "schemaVersion": resultSchema,
            "phase": request.phase.rawValue,
            "requestID": request.requestID,
            "requestSHA256": MirmirNotarizedSmokeFilesV4.sha256(requestData),
            "applicationArchiveSHA256": request.applicationArchiveSHA256,
            "sourceCommit": request.sourceCommit,
            "observedAtUTC": utcNow(),
            "resultFileName": "prepare-result.json",
            "process": try MirmirNotarizedSmokeFilesV4.object(process),
            "runtime": try MirmirNotarizedSmokeFilesV4.object(runtime),
            "mediaProbe": try MirmirNotarizedSmokeFilesV4.object(inputProbe),
            "inputSemantic": try MirmirNotarizedSmokeFilesV4.object(
                inputSemantic
            ),
            "deterministicProcess": try MirmirNotarizedSmokeFilesV4.object(
                directProcessing
            ),
            "directOutputSemantic": try MirmirNotarizedSmokeFilesV4.object(
                directSemantic
            ),
            "queue": [
                "jobID": pausedJobID.rawValue,
                "lifecycle": WorkflowJobLifecycle.paused.rawValue,
                "checkpointRelatedFileCount": checkpointRelatedFiles,
                "queueTreeSHA256": queueTreeSHA256
            ],
            "artifacts": [
                "input": try MirmirNotarizedSmokeFilesV4.object(inputArtifact),
                "directOutput": try MirmirNotarizedSmokeFilesV4.object(
                    directArtifact
                ),
                "phaseOneState": try MirmirNotarizedSmokeFilesV4.object(
                    stateArtifact
                )
            ],
            "checks": [
                "shippingExecutableIdentity": true,
                "sandboxIsolation": true,
                "productionP06Load": true,
                "realMediaProbe": true,
                "deterministicCPUProcess": true,
                "durableCheckpointPause": true,
                "userQueueUntouched": true
            ]
        ]
        let resultData = try MirmirNotarizedSmokeFilesV4.canonicalData(result)
        try MirmirNotarizedSmokeFilesV4.writeNew(
            resultData,
            to: context.root.appendingPathComponent("prepare-result.json")
        )
        return resultData
    }

    private static func recover(
        _ request: MirmirNotarizedSmokeRequestV4
    ) async throws -> Data {
        let context = try qualificationContext(request: request, create: false)
        let requestData = try MirmirNotarizedSmokeFilesV4.canonicalData(request)
        try MirmirNotarizedSmokeFilesV4.writeNew(
            requestData,
            to: context.root.appendingPathComponent("recover-request.json")
        )
        let process = try processIdentity(request: request, context: context)
        let runtime = try runtimeIdentity(request: request)
        let stateURL = context.root.appendingPathComponent(
            "phase-one-state.json"
        )
        let state = try MirmirNotarizedSmokeFilesV4.decodeCanonical(
            MirmirSmokePhaseOneStateV4.self,
            from: stateURL
        )
        guard state.schemaVersion == MirmirSmokePhaseOneStateV4.schema,
              state.requestID == request.requestID,
              state.nonceSHA256 == MirmirNotarizedSmokeFilesV4.sha256(
                Data(request.nonce.utf8)
              ),
              state.applicationArchiveSHA256
                == request.applicationArchiveSHA256,
              state.sourceCommit == request.sourceCommit,
              state.executableSHA256 == process.executableSHA256,
              state.runtimeManifestSHA256 == runtime.manifestSHA256,
              state.runtimeManifestFileSHA256 == runtime.manifestFileSHA256
        else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "phase-one state belongs to another request, app, or runtime"
            )
        }
        let phaseOneResultURL = context.root.appendingPathComponent(
            "prepare-result.json"
        )
        guard let requiredPhaseOneHash = request.phaseOneResultSHA256,
              try MirmirNotarizedSmokeFilesV4.sha256(phaseOneResultURL)
                == requiredPhaseOneHash else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "phase-one result seal"
            )
        }
        let mediaDirectory = context.root.appendingPathComponent(
            "media",
            isDirectory: true
        )
        let inputURL = mediaDirectory.appendingPathComponent("source.mov")
        let directURL = mediaDirectory.appendingPathComponent(
            "uninterrupted.mov"
        )
        let queueOutputURL = mediaDirectory.appendingPathComponent(
            "recovered.mov"
        )
        guard try MirmirNotarizedSmokeFilesV4.artifact(
            root: context.root,
            url: inputURL
        ) == state.inputArtifact,
              try MirmirNotarizedSmokeFilesV4.artifact(
                root: context.root,
                url: directURL
              ) == state.directOutputArtifact,
              try await semanticIdentity(at: inputURL) == state.inputSemantic,
              try await semanticIdentity(at: directURL)
                == state.directOutputSemantic else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "phase-one media artifacts changed before relaunch"
            )
        }
        let queueRoot = context.root.appendingPathComponent(
            "workflow-queue-v4",
            isDirectory: true
        )
        guard try MirmirNotarizedSmokeFilesV4.treeSHA256(queueRoot)
                == state.queueTreeSHA256 else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "durable queue changed between app processes"
            )
        }
        let coordinator = try workflowCoordinator(
            queueRoot: queueRoot,
            worker: "recover-\(request.requestID.prefix(12))"
        )
        let launch = try await coordinator.launch()
        let recoveryItem = launch.recovery.items.first
        guard launch.queue.items.count == 1,
              launch.queue.items[0].jobID.rawValue == state.jobID,
              launch.queue.items[0].lifecycle == .paused,
              launch.queue.items[0].requestRecordStatus == .ready,
              launch.recovery.items.count == 1,
              recoveryItem?.jobID.rawValue == state.jobID,
              recoveryItem?.observedLifecycle == .paused,
              recoveryItem?.presentedLifecycle == .paused,
              recoveryItem?.status == .idle,
              recoveryItem?.resumable == true,
              recoveryItem?.containedFailureCount == 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "relaunch did not reopen exactly one resumable paused job"
            )
        }
        let jobID = try WorkflowJobID(state.jobID)
        let outcome = try await coordinator.resume(
            jobID: jobID,
            progress: { _ in },
            snapshot: { _ in }
        )
        let completion: WorkflowApplicationCompletionV4
        switch outcome {
        case .completed(let value):
            completion = value
        case .paused:
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the relaunched queue paused again instead of completing"
            )
        }
        let resumedProcessing = try processingIdentity(completion.result)
        guard completion.result.outputURL.standardizedFileURL
                == queueOutputURL.standardizedFileURL,
              resumedProcessing.actualBackendID
                == UpscaleBackendID.mirmirDeterministicCPU.rawValue else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "relaunch completed through another output or backend"
            )
        }
        let finalSnapshot = try await coordinator.queueSnapshot()
        guard finalSnapshot.items.count == 1,
              finalSnapshot.items[0].jobID == jobID,
              finalSnapshot.items[0].lifecycle == .completed else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the resumed queue job did not reach completed"
            )
        }
        let recoveredSemantic = try await semanticIdentity(at: queueOutputURL)
        guard recoveredSemantic == state.directOutputSemantic else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "decoded pixels or timing differ after checkpoint relaunch"
            )
        }
        let recoveredArtifact = try MirmirNotarizedSmokeFilesV4.artifact(
            root: context.root,
            url: queueOutputURL
        )
        let finalQueueTreeSHA256 = try MirmirNotarizedSmokeFilesV4.treeSHA256(
            queueRoot
        )
        let result: [String: Any] = [
            "schemaVersion": resultSchema,
            "phase": request.phase.rawValue,
            "requestID": request.requestID,
            "requestSHA256": MirmirNotarizedSmokeFilesV4.sha256(requestData),
            "phaseOneResultSHA256": requiredPhaseOneHash,
            "applicationArchiveSHA256": request.applicationArchiveSHA256,
            "sourceCommit": request.sourceCommit,
            "observedAtUTC": utcNow(),
            "resultFileName": "recover-result.json",
            "process": try MirmirNotarizedSmokeFilesV4.object(process),
            "runtime": try MirmirNotarizedSmokeFilesV4.object(runtime),
            "resumedProcess": try MirmirNotarizedSmokeFilesV4.object(
                resumedProcessing
            ),
            "referenceSemantic": try MirmirNotarizedSmokeFilesV4.object(
                state.directOutputSemantic
            ),
            "recoveredSemantic": try MirmirNotarizedSmokeFilesV4.object(
                recoveredSemantic
            ),
            "queue": [
                "jobID": state.jobID,
                "launchLifecycle": WorkflowJobLifecycle.paused.rawValue,
                "finalLifecycle": WorkflowJobLifecycle.completed.rawValue,
                "launchRecoveryItemCount": launch.recovery.items.count,
                "launchRecoveryStatus": recoveryItem!.status.rawValue,
                "launchRecoveryObservedLifecycle": recoveryItem!
                    .observedLifecycle.rawValue,
                "launchRecoveryPresentedLifecycle": recoveryItem!
                    .presentedLifecycle.rawValue,
                "launchRecoveryResumable": recoveryItem!.resumable,
                "launchRecoveryContainedFailureCount": recoveryItem!
                    .containedFailureCount,
                "phaseOneQueueTreeSHA256": state.queueTreeSHA256,
                "finalQueueTreeSHA256": finalQueueTreeSHA256
            ],
            "artifacts": [
                "directOutput": try MirmirNotarizedSmokeFilesV4.object(
                    state.directOutputArtifact
                ),
                "recoveredOutput": try MirmirNotarizedSmokeFilesV4.object(
                    recoveredArtifact
                ),
                "phaseOneState": try MirmirNotarizedSmokeFilesV4.object(
                    try MirmirNotarizedSmokeFilesV4.artifact(
                        root: context.root,
                        url: stateURL
                    )
                )
            ],
            "checks": [
                "shippingExecutableIdentity": true,
                "sandboxIsolation": true,
                "productionP06Load": true,
                "phaseOneSealReplayVerified": true,
                "durableQueueReopened": true,
                "checkpointResumeCompleted": true,
                "decodedSemanticEquality": true,
                "userQueueUntouched": true
            ]
        ]
        let resultData = try MirmirNotarizedSmokeFilesV4.canonicalData(result)
        try MirmirNotarizedSmokeFilesV4.writeNew(
            resultData,
            to: context.root.appendingPathComponent("recover-result.json")
        )
        return resultData
    }
}

private extension MirmirNotarizedSmokeObserverV4 {
    static func utcNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    static func qualificationContext(
        request: MirmirNotarizedSmokeRequestV4,
        create: Bool
    ) throws -> QualificationContext {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let marker = "/Library/Containers/\(request.bundleIdentifier)/Data"
        guard let markerRange = support.path.range(of: marker),
              markerRange.upperBound < support.path.endIndex,
              support.path[markerRange.upperBound...] == "/Library/Application Support"
        else {
            throw MirmirNotarizedSmokeErrorV4.unsafeQualificationRoot(
                support.path
            )
        }
        let sandboxPath = String(support.path[..<markerRange.upperBound])
        let sandboxData = URL(fileURLWithPath: sandboxPath, isDirectory: true)
            .standardizedFileURL
        let qualificationDirectory = support.appendingPathComponent(
            "MirmirQualificationV4",
            isDirectory: true
        )
        try makeSecureDirectory(qualificationDirectory)
        let namespace = qualificationDirectory.appendingPathComponent(
            "notarized-smoke",
            isDirectory: true
        )
        try makeSecureDirectory(namespace)
        try validateOwnedDirectory(namespace)
        let root = namespace.appendingPathComponent(
            request.requestID,
            isDirectory: true
        ).standardizedFileURL
        guard root.deletingLastPathComponent() == namespace else {
            throw MirmirNotarizedSmokeErrorV4.unsafeQualificationRoot(root.path)
        }
        if create {
            guard !fileManager.fileExists(atPath: root.path) else {
                throw MirmirNotarizedSmokeErrorV4.unsafeQualificationRoot(
                    "request root already exists: \(root.path)"
                )
            }
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try validateOwnedDirectory(root)
        return QualificationContext(
            root: root,
            applicationSupport: support,
            sandboxData: sandboxData
        )
    }

    static func validateOwnedDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_nlink >= 1,
              metadata.st_mode & 0o022 == 0 else {
            throw MirmirNotarizedSmokeErrorV4.unsafeQualificationRoot(url.path)
        }
    }

    static func makeSecureDirectory(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            try validateOwnedDirectory(url)
            return
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try validateOwnedDirectory(url)
    }

    static func processIdentity(
        request: MirmirNotarizedSmokeRequestV4,
        context: QualificationContext
    ) throws -> MirmirSmokeProcessIdentityV4 {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let version = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              let build = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
              ) as? String,
              let executable = Bundle.main.executableURL else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "the shipping bundle omits executable metadata"
            )
        }
        let bundle = Bundle.main.bundleURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let executableURL = executable.standardizedFileURL
            .resolvingSymlinksInPath()
        let executableSHA256 = try MirmirNotarizedSmokeFilesV4.sha256(
            executableURL
        )
        guard bundleID == request.bundleIdentifier,
              version == request.productVersion,
              build == request.productBuild,
              executableSHA256 == request.expectedExecutableSHA256,
              executableURL.path.hasPrefix(bundle.path + "/Contents/MacOS/")
        else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "bundle ID, version, build, or executable SHA-256"
            )
        }
        return MirmirSmokeProcessIdentityV4(
            bundleIdentifier: bundleID,
            productVersion: version,
            productBuild: build,
            bundlePath: bundle.path,
            executablePath: executableURL.path,
            executableSHA256: executableSHA256,
            processID: ProcessInfo.processInfo.processIdentifier,
            parentProcessID: getppid(),
            sandboxDataPath: context.sandboxData.path,
            applicationSupportPath: context.applicationSupport.path,
            qualificationRootPath: context.root.path
        )
    }

    static func runtimeIdentity(
        request: MirmirNotarizedSmokeRequestV4
    ) throws -> MirmirSmokeRuntimeIdentityV4 {
        guard ASHProductionP06TrustRootV4.isConfigured,
              ASHProductionP06TrustRootV4.manifestSHA256.rawValue
                == request.runtimeManifestSHA256 else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "the code-owned P06 trust root"
            )
        }
        let runtime = try ASHP06RuntimeProviderV4.production().load()
        try runtime.verifyBinding()
        try runtime.manifest.validate(requiring: .releaseQualified)
        _ = try runtime.measurementContract()
        _ = try runtime.branchProgram()
        _ = try runtime.verificationContract()
        let manifestURL = runtime.bundleURL.appendingPathComponent(
            ASHRuntimeManifestV4.fileName
        )
        let manifestFileSHA256 = try MirmirNotarizedSmokeFilesV4.sha256(
            manifestURL
        )
        guard runtime.manifestSHA256.rawValue
                == request.runtimeManifestSHA256,
              manifestFileSHA256 == request.runtimeManifestFileSHA256,
              runtime.manifest.runtimeID == ASHRuntimeManifestV4.runtimeIdentity,
              runtime.manifest.releaseStatus == .releaseQualified,
              runtime.manifest.provenance.sourceRevision
                == ASHProductionP06TrustRootV4.sourceRevision,
              runtime.manifest.provenance.builderSourceSHA256
                == ASHProductionP06TrustRootV4.builderSourceSHA256,
              runtime.manifest.artifacts.count
                == ASHRuntimeArtifactRoleV4.allCases.count else {
            throw MirmirNotarizedSmokeErrorV4.identityMismatch(
                "the loaded P06 release bundle"
            )
        }
        return MirmirSmokeRuntimeIdentityV4(
            runtimeID: runtime.manifest.runtimeID,
            releaseStatus: runtime.manifest.releaseStatus.rawValue,
            manifestSHA256: runtime.manifestSHA256.rawValue,
            manifestFileSHA256: manifestFileSHA256,
            sourceRevision: runtime.manifest.provenance.sourceRevision,
            builderSourceSHA256:
                runtime.manifest.provenance.builderSourceSHA256.rawValue,
            artifactCount: runtime.manifest.artifacts.count,
            runtimeBundlePath: runtime.bundleURL.standardizedFileURL.path,
            trustRootConfigured: ASHProductionP06TrustRootV4.isConfigured
        )
    }

    static func processingRequest(input: URL, output: URL) -> UpscaleRequest {
        UpscaleRequest(
            inputURL: input,
            outputURL: output,
            backendID: .mirmirDeterministicCPU,
            targetWidth: 96,
            targetHeight: 72,
            outputCodec: .h264,
            preserveAudio: false,
            overwriteExistingFile: false
        )
    }

    static func processingIdentity(
        _ result: UpscaleResult
    ) throws -> MirmirSmokeProcessingIdentityV4 {
        guard result.processingDurationSeconds.isFinite,
              result.processingDurationSeconds > 0,
              result.processedFrameCount > 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "processing returned non-finite or empty measurements"
            )
        }
        return MirmirSmokeProcessingIdentityV4(
            actualBackendID: result.actualBackendID.rawValue,
            processedFrameCount: result.processedFrameCount,
            encodedWidth: result.encodedWidth,
            encodedHeight: result.encodedHeight,
            outputCodec: result.outputCodec.rawValue,
            processingDurationSeconds: result.processingDurationSeconds
        )
    }

    static func workflowCoordinator(
        queueRoot: URL,
        worker: String
    ) throws -> WorkflowApplicationCoordinatorV4 {
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: queueRoot,
            workerID: WorkflowWorkerIDV4("notarized-smoke-\(worker)"),
            maximumConcurrentJobs: 1
        )
        let engine = WorkflowDeterministicApplicationEngineV4(
            videoProbe: VideoProbe(),
            backendCatalog: .live(),
            runtimeEnvironment: .current()
        )
        return WorkflowApplicationCoordinatorV4(
            queue: queue,
            engine: engine,
            maximumInputFramesPerBoundary: 1
        )
    }

    static func regularFileCount(root: URL, pathContains token: String) throws
        -> Int {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "cannot enumerate durable queue"
            )
        }
        var count = 0
        for case let url as URL in enumerator where url.path.contains(token) {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw MirmirNotarizedSmokeErrorV4.invariant(
                    "durable queue entry disappeared"
                )
            }
            if metadata.st_mode & S_IFMT == S_IFREG { count += 1 }
        }
        if let enumerationError {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "durable queue enumeration failed: "
                    + enumerationError.localizedDescription
            )
        }
        return count
    }
}

private extension MirmirNotarizedSmokeObserverV4 {
    static func makeSourceMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 48,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey:
                    AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey:
                    AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 1
            ]
        ]
        guard writer.canApply(
            outputSettings: settings,
            forMediaType: .video
        ) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "AVAssetWriter rejected the locked H.264 fixture"
            )
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "AVAssetWriter rejected the fixture video input"
            )
        }
        writer.add(input)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 48,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        guard writer.startWriting() else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                writer.error?.localizedDescription
                    ?? "AVAssetWriter did not start"
            )
        }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                64,
                48,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attributes as CFDictionary,
                &buffer
            )
            guard status == kCVReturnSuccess, let buffer else {
                throw MirmirNotarizedSmokeErrorV4.invariant(
                    "CoreVideo could not allocate fixture frame \(status)"
                )
            }
            try fillSourceFrame(buffer, frame: frame)
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_ITU_R_709_2,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_ITU_R_709_2,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate
            )
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw MirmirNotarizedSmokeErrorV4.invariant(
                        writer.error?.localizedDescription
                            ?? "fixture writer stopped before append"
                    )
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(
                    value: Int64(frame),
                    timescale: 30
                )
            ) else {
                throw MirmirNotarizedSmokeErrorV4.invariant(
                    writer.error?.localizedDescription
                        ?? "fixture writer rejected a frame"
                )
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                writer.error?.localizedDescription
                    ?? "fixture writer did not finish"
            )
        }
    }

    static func fillSourceFrame(_ buffer: CVPixelBuffer, frame: Int) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?
                .assumingMemoryBound(to: UInt8.self),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?
                .assumingMemoryBound(to: UInt8.self) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "fixture buffer is not writable NV12"
            )
        }
        let lumaWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<lumaHeight {
            let row = luma.advanced(by: y * lumaStride)
            for x in 0..<lumaWidth {
                // Keep the encoded fixture comfortably inside studio-swing
                // bounds. Lossy H.264 reconstruction may overshoot a source
                // code by one or more values; touching 16/235 here can turn a
                // valid writer input into an out-of-contract decoded frame.
                row[x] = UInt8(40 + ((x * 3 + y * 5 + frame * 11) % 176))
            }
        }
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<chromaHeight {
            let row = chroma.advanced(by: y * chromaStride)
            for x in 0..<chromaWidth {
                row[x * 2] = UInt8(80 + ((x * 7 + frame * 13) % 96))
                row[x * 2 + 1] = UInt8(80 + ((y * 9 + frame * 17) % 96))
            }
        }
    }

    static func probeIdentity(
        _ source: VideoInfo
    ) throws -> MirmirSmokeProbeIdentityV4 {
        guard let encoded = source.geometry.encodedSize,
              let width = Int(exactly: encoded.width),
              let height = Int(exactly: encoded.height),
              let codec = source.codecFourCC,
              let estimatedFrameCount = source.estimatedFrameCount else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "VideoProbe omitted locked fixture facts"
            )
        }
        let codecFourCC = fourCC(codec)
        guard codecFourCC == "avc1" else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the locked fixture writer produced another codec"
            )
        }
        // Some OS releases omit default H.264 format-description extensions.
        // The fallback facts are not guesses: makeSourceMovie locks an 8-bit
        // video-range NV12 input and progressive H.264 High profile. The
        // evidence-source fields make this normalization explicit.
        let bitDepth = source.color.bitDepth ?? 8
        let bitDepthEvidence = source.color.bitDepth == nil
            ? "locked_h264_writer_contract"
            : "format_description"
        let isFullRange = source.color.isFullRange ?? false
        let rangeEvidence = source.color.isFullRange == nil
            ? "locked_h264_writer_contract"
            : "format_description"
        let fieldCount = source.color.fieldCount ?? 1
        let fieldCountEvidence = source.color.fieldCount == nil
            ? "locked_h264_writer_contract"
            : "format_description"
        let duration = normalizedTime(source.duration)
        return MirmirSmokeProbeIdentityV4(
            encodedWidth: width,
            encodedHeight: height,
            codecFourCC: codecFourCC,
            durationValue: duration.value,
            durationTimescale: duration.timescale,
            estimatedFrameCount: estimatedFrameCount,
            videoTrackCount: source.videoTrackCount,
            audioTrackCount: source.audioTrackCount,
            bitDepth: bitDepth,
            bitDepthEvidence: bitDepthEvidence,
            isFullRange: isFullRange,
            rangeEvidence: rangeEvidence,
            dynamicRange: source.color.dynamicRange.rawValue,
            fieldCount: fieldCount,
            fieldCountEvidence: fieldCountEvidence,
            readable: source.isReadable,
            playable: source.isPlayable
        )
    }

    static func validateLockedInput(
        probe: MirmirSmokeProbeIdentityV4,
        semantic: MirmirSmokeSemanticIdentityV4
    ) throws {
        guard probe.encodedWidth == 64,
              probe.encodedHeight == 48,
              probe.codecFourCC == "avc1",
              probe.videoTrackCount == 1,
              probe.audioTrackCount == 0,
              probe.bitDepth == 8,
              !probe.isFullRange,
              probe.dynamicRange == VideoDynamicRange.sdr.rawValue,
              probe.fieldCount == 1,
              probe.readable,
              probe.playable,
              semantic.encodedWidth == 64,
              semantic.encodedHeight == 48,
              semantic.frameCount == 12,
              semantic.enabledVideoTrackCount == 1 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "the generated source does not satisfy the locked real-media contract"
            )
        }
    }

    static func semanticIdentity(at url: URL) async throws
        -> MirmirSmokeSemanticIdentityV4 {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let (duration, tracks) = try await asset.load(.duration, .tracks)
        var enabled: [AVAssetTrack] = []
        for track in tracks where track.mediaType == .video {
            if try await track.load(.isEnabled) { enabled.append(track) }
        }
        guard enabled.count == 1, let track = enabled.first else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "semantic verification requires one enabled video track"
            )
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "semantic verification found no video format"
            )
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0, dimensions.height > 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "semantic verification found invalid dimensions"
            )
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                "AVFoundation rejected the semantic decoder"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                reader.error?.localizedDescription
                    ?? "semantic decoder did not start"
            )
        }
        var timingDigest = SHA256()
        timingDigest.update(data: Data("mirmir-smoke-timing-v1\0".utf8))
        var pixelDigest = SHA256()
        pixelDigest.update(data: Data("mirmir-smoke-visible-pixels-v1\0".utf8))
        var frameCount = 0
        while let sample = output.copyNextSampleBuffer() {
            let presentation = normalizedTime(
                CMSampleBufferGetPresentationTimeStamp(sample)
            )
            let rawDuration = CMSampleBufferGetDuration(sample)
            let sampleDuration = rawDuration.isValid && rawDuration.isNumeric
                ? normalizedTime(rawDuration)
                : CMTime(value: 0, timescale: 600_000)
            let timing = "\(frameCount):\(presentation.value)/"
                + "\(presentation.timescale):\(sampleDuration.value)/"
                + "\(sampleDuration.timescale)\n"
            timingDigest.update(data: Data(timing.utf8))
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferGetPlaneCount(buffer) == 2 else {
                throw MirmirNotarizedSmokeErrorV4.invariant(
                    "semantic decoder did not return planar NV12"
                )
            }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            for plane in 0..<2 {
                let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
                let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let visibleBytes = width * (plane == 0 ? 1 : 2)
                guard visibleBytes > 0,
                      height > 0,
                      stride >= visibleBytes,
                      let base = CVPixelBufferGetBaseAddressOfPlane(
                        buffer,
                        plane
                      )?.assumingMemoryBound(to: UInt8.self) else {
                    throw MirmirNotarizedSmokeErrorV4.invariant(
                        "semantic decoder returned unsafe plane geometry"
                    )
                }
                for row in 0..<height {
                    pixelDigest.update(data: Data(
                        bytes: base.advanced(by: row * stride),
                        count: visibleBytes
                    ))
                }
            }
            frameCount += 1
        }
        guard reader.status == .completed, frameCount > 0 else {
            throw MirmirNotarizedSmokeErrorV4.invariant(
                reader.error?.localizedDescription
                    ?? "semantic decoder did not complete"
            )
        }
        let normalizedDuration = normalizedTime(duration)
        return MirmirSmokeSemanticIdentityV4(
            encodedWidth: Int(dimensions.width),
            encodedHeight: Int(dimensions.height),
            frameCount: frameCount,
            enabledVideoTrackCount: enabled.count,
            durationValue: normalizedDuration.value,
            durationTimescale: normalizedDuration.timescale,
            timingSHA256: MirmirNotarizedSmokeFilesV4.hex(
                timingDigest.finalize()
            ),
            visiblePixelSHA256: MirmirNotarizedSmokeFilesV4.hex(
                pixelDigest.finalize()
            )
        )
    }

    static func normalizedTime(_ value: CMTime) -> CMTime {
        guard value.isValid && value.isNumeric else {
            return CMTime(value: 0, timescale: 600_000)
        }
        return CMTimeConvertScale(
            value,
            timescale: 600_000,
            method: .default
        )
    }

    static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????????"
    }
}

private enum MirmirPackagedParityCaptureV4 {
    static func capture(
        environment: [String: String],
        packageIdentity: MirmirPackagedCandidateIdentityV4,
        requestSHA256: String
    ) async throws -> URL {
        guard let outputPath = environment[
            "MIRMIR_PARITY_CAPTURE_DIRECTORY"
        ],
              !outputPath.isEmpty else {
            throw ParityCaptureError.invalidEnvironment(
                "parity capture directory is absent"
            )
        }
        let contractPath = try requiredEnvironment(
            "MIRMIR_PARITY_CONTRACT_PATH",
            in: environment
        )
        let contractData = try Data(
            contentsOf: URL(fileURLWithPath: contractPath)
        )
        let contract = try JSONDecoder().decode(
            ParityCaptureContract.self,
            from: contractData
        )
        try contract.validate()
        let contractSHA256 = sha256(contractData)
        guard contractSHA256 == (try requiredEnvironment(
            "MIRMIR_PARITY_CONTRACT_SHA256",
            in: environment
        )), contract.tools.captureSourceSHA256 == (try requiredEnvironment(
            "MIRMIR_PARITY_CAPTURE_SOURCE_SHA256",
            in: environment
        )) else {
            throw ParityCaptureError.invalidEnvironment(
                "the executing contract or capture source is not sealed"
            )
        }

        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try createNewDirectory(output)
        let runtimeMode = environment["MIRMIR_PARITY_RUNTIME_MODE"]
            ?? "production"
        let runtime = try loadRuntime(mode: runtimeMode)
        try runtime.verifyBinding()
        let runtimeRecord = try makeRuntimeRecord(
            runtime,
            mode: runtimeMode,
            expected: contract.releaseRuntime
        )
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw ParityCaptureError.metalUnavailable
        }

        var cases: [ParityCapturedCase] = []
        for definition in contract.cases {
            let directory = output
                .appendingPathComponent("cases", isDirectory: true)
                .appendingPathComponent(definition.id, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            cases.append(try await captureCase(
                definition,
                contract: contract,
                runtime: runtime,
                outputRoot: output,
                directory: directory
            ))
        }

        let capture = ParityCapture(
            schemaVersion: contract.captureSchemaVersion,
            contractSHA256: contractSHA256,
            captureSourceSHA256: contract.tools.captureSourceSHA256,
            sourceRevision: try requiredEnvironment(
                "MIRMIR_PARITY_SOURCE_REVISION",
                in: environment
            ),
            buildConfiguration: try requiredEnvironment(
                "MIRMIR_PARITY_BUILD_CONFIGURATION",
                in: environment
            ),
            processRunID: try requiredEnvironment(
                "MIRMIR_PARITY_PROCESS_RUN_ID",
                in: environment
            ),
            evidenceRequestSHA256: requestSHA256,
            packagedCandidateIdentity: packageIdentity,
            runtime: runtimeRecord,
            cases: cases
        )
        let captureURL = output.appendingPathComponent("capture.json")
        try canonicalJSON(capture).write(
            to: captureURL,
            options: .atomic
        )
        let manifest = try makeArtifactManifest(
            root: output,
            excluding: ["artifact-manifest.json"]
        )
        try canonicalJSON(manifest).write(
            to: output.appendingPathComponent("artifact-manifest.json"),
            options: .atomic
        )
        return captureURL
    }

    private enum ParityCaptureError: Error, CustomStringConvertible {
        case invalidContract(String)
        case invalidEnvironment(String)
        case invalidOutput(String)
        case invalidFixture(String)
        case parityFailure(String)
        case metalUnavailable

        var description: String {
            switch self {
            case .invalidContract(let value): "invalid parity contract: \(value)"
            case .invalidEnvironment(let value): "invalid environment: \(value)"
            case .invalidOutput(let value): "invalid parity output: \(value)"
            case .invalidFixture(let value): "invalid parity fixture: \(value)"
            case .parityFailure(let value): "parity failure: \(value)"
            case .metalUnavailable: "Metal is unavailable"
            }
        }
    }

    private struct ParityCaptureContract: Decodable {
        let schemaVersion: String
        let gateID: String
        let buildConfiguration: String
        let captureSchemaVersion: String
        let reportSchemaVersion: String
        let runArtifactSchemaVersion: String
        let attachmentSchemaVersion: String
        let comparison: String
        let repeatExecutionCount: Int
        let crossProcessCaptureCount: Int
        let boundedTemporalCaseID: String
        let temporalTilePolicy: ParityTemporalTilePolicy
        let schedulePairs: [ParitySchedulePair]
        let tileSchedules: [String]
        let parityCoverage: [String]
        let releaseRuntime: ParityReleaseRuntimeContract
        let tools: ParityToolIdentities
        let cases: [ParityCaseDefinition]

        func validate() throws {
            guard schemaVersion
                    == "mirmir-ash-v4-cpu-metal-parity-contract-v2",
                  gateID == "deterministic-engine-v4-cpu-metal-byte-parity",
                  buildConfiguration == "Release",
                  captureSchemaVersion
                    == "mirmir-ash-v4-cpu-metal-parity-capture-v2",
                  reportSchemaVersion
                    == "mirmir-ash-v4-cpu-metal-parity-report-v2",
                  runArtifactSchemaVersion
                    == "mirmir-ash-v4-cpu-metal-parity-run-v2",
                  attachmentSchemaVersion
                    == "mirmir-ash-v4-canonical-semantics-v2",
                  comparison
                    == "exact_visible_plane_attachment_timeline_checkpoint_and_resume_bytes",
                  repeatExecutionCount == 2,
                  crossProcessCaptureCount == 2,
                  boundedTemporalCaseID
                    == "nv12-video-forced-tiled-temporal-16x12-to-32x24",
                  temporalTilePolicy == .qualification,
                  schedulePairs == [
                    ParitySchedulePair(
                        spatialSchedule: "row_major",
                        temporalSchedule: "raster"
                    ),
                    ParitySchedulePair(
                        spatialSchedule: "reverse",
                        temporalSchedule: "reverse_raster"
                    ),
                    ParitySchedulePair(
                        spatialSchedule: "even_then_odd",
                        temporalSchedule: "even_then_odd"
                    )
                  ],
                  tileSchedules == ["row_major", "reverse", "even_then_odd"],
                  parityCoverage.count == 34,
                  Set(parityCoverage).count == parityCoverage.count,
                  cases.count == 11,
                  Set(cases.map(\.id)).count == cases.count else {
                throw ParityCaptureError.invalidContract("header or count mismatch")
            }
            guard Set(cases.flatMap(\.coverage)) == Set(parityCoverage) else {
                throw ParityCaptureError.invalidContract("coverage is not exact")
            }
            for value in [
                tools.captureSourceSHA256,
                tools.evaluatorSHA256,
                tools.runnerSHA256
            ] where !isSHA256(value) {
                throw ParityCaptureError.invalidContract("invalid tool identity")
            }
            for definition in cases {
                try definition.validate(allowedCoverage: Set(parityCoverage))
            }
            guard let bounded = cases.first(where: {
                $0.id == boundedTemporalCaseID
            }), bounded.kind == "pixel_temporal",
            bounded.scanMode == "progressive",
            bounded.sourceWidth == 16,
            bounded.sourceHeight == 12,
            bounded.targetWidth == 32,
            bounded.targetHeight == 24,
            bounded.checkpointBoundaries == [1, 3],
            bounded.frames.map(\.pattern) == [
                "moving_edge_0",
                "moving_edge_1",
                "moving_edge_2",
                "periodic_phase_0",
                "periodic_phase_1"
            ],
            bounded.frames.map(\.temporalResetReason) == [
                nil, nil, nil, "seek", nil
            ],
            bounded.coverage.contains("seek_reset") else {
                throw ParityCaptureError.invalidContract(
                    "bounded temporal case differs"
                )
            }
            guard let repeated = cases.first(where: {
                $0.id == "nv12-video-periodic-ambiguous-8x6-to-15x11"
            }), repeated.kind == "pixel_temporal",
            repeated.scanMode == "progressive",
            repeated.storage == "nv12_video_range_8",
            repeated.sourceWidth == 8,
            repeated.sourceHeight == 6,
            repeated.targetWidth == 15,
            repeated.targetHeight == 11,
            repeated.frames.map(\.pattern) == [
                "periodic_phase_0",
                "periodic_phase_1",
                "periodic_phase_0",
                "periodic_phase_1"
            ],
            repeated.frames.allSatisfy({ $0.temporalResetReason == nil }),
            repeated.checkpointBoundaries == [1],
            repeated.coverage == ["repeated_pattern"] else {
                throw ParityCaptureError.invalidContract(
                    "periodic ambiguous temporal case differs"
                )
            }
        }
    }

    private struct ParityTemporalTilePolicy: Codable, Equatable {
        let policyID: String
        let tileWidth: Int
        let tileHeight: Int
        let searchHalo: Int
        let maximumFrameWidth: Int
        let maximumFrameHeight: Int

        static let qualification = Self(
            policyID: "ash.release.parity.tiles.8x8-halo5-max64-v1",
            tileWidth: 8,
            tileHeight: 8,
            searchHalo: 5,
            maximumFrameWidth: 64,
            maximumFrameHeight: 64
        )

        func enginePolicy() throws -> ASHTemporalTilePolicyV4 {
            try ASHTemporalTilePolicyV4(
                policyID: policyID,
                tileWidth: tileWidth,
                tileHeight: tileHeight,
                searchHalo: searchHalo,
                maximumFrameWidth: maximumFrameWidth,
                maximumFrameHeight: maximumFrameHeight
            )
        }
    }

    private struct ParitySchedulePair: Codable, Equatable {
        let spatialSchedule: String
        let temporalSchedule: String
    }

    private struct ParityReleaseRuntimeContract: Decodable {
        let bundleRepositoryPath: String
        let trustRootSourceRepositoryPath: String
        let runtimeID: String
        let requiredReleaseStatus: String
    }

    private struct ParityToolIdentities: Codable, Equatable {
        let captureSourceSHA256: String
        let evaluatorSHA256: String
        let runnerSHA256: String
    }

    private struct ParityTimeDefinition: Codable, Equatable {
        let value: Int64
        let timescale: Int32
    }

    private struct ParityFrameDefinition: Codable, Equatable {
        let pattern: String
        let topToken: Int?
        let bottomToken: Int?
        let presentationTime: ParityTimeDefinition
        let duration: ParityTimeDefinition
        let fieldDetail: String
        let hdrProfile: String
        let temporalResetReason: String?

        enum CodingKeys: String, CodingKey {
            case pattern
            case topToken
            case bottomToken
            case presentationTime
            case duration
            case fieldDetail
            case hdrProfile
            case temporalResetReason
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pattern, forKey: .pattern)
            if let topToken {
                try container.encode(topToken, forKey: .topToken)
            } else {
                try container.encodeNil(forKey: .topToken)
            }
            if let bottomToken {
                try container.encode(bottomToken, forKey: .bottomToken)
            } else {
                try container.encodeNil(forKey: .bottomToken)
            }
            try container.encode(presentationTime, forKey: .presentationTime)
            try container.encode(duration, forKey: .duration)
            try container.encode(fieldDetail, forKey: .fieldDetail)
            try container.encode(hdrProfile, forKey: .hdrProfile)
            try container.encodeIfPresent(
                temporalResetReason,
                forKey: .temporalResetReason
            )
        }
    }

    private struct ParityStateExpectation: Codable, Equatable {
        let inputOrdinal: Int
        let dominance: String?
        let classification: String?
        let cadenceID: String
        let historyGeneration: UInt64

        enum CodingKeys: String, CodingKey {
            case inputOrdinal
            case dominance
            case classification
            case cadenceID
            case historyGeneration
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(inputOrdinal, forKey: .inputOrdinal)
            if let dominance {
                try container.encode(dominance, forKey: .dominance)
            } else {
                try container.encodeNil(forKey: .dominance)
            }
            if let classification {
                try container.encode(classification, forKey: .classification)
            } else {
                try container.encodeNil(forKey: .classification)
            }
            try container.encode(cadenceID, forKey: .cadenceID)
            try container.encode(historyGeneration, forKey: .historyGeneration)
        }
    }

    private struct ParityCaseDefinition: Codable, Equatable {
        let id: String
        let kind: String
        let storage: String
        let association: String
        let scanMode: String
        let sourceWidth: Int
        let sourceHeight: Int
        let targetWidth: Int
        let targetHeight: Int
        let frames: [ParityFrameDefinition]
        let checkpointBoundaries: [Int]
        let stateExpectations: [ParityStateExpectation]
        let coverage: [String]

        func validate(allowedCoverage: Set<String>) throws {
            let kinds = [
                "pixel_spatial",
                "pixel_temporal",
                "pixel_interlaced_temporal",
                "alpha_spatial"
            ]
            guard id.range(
                of: "^[a-z0-9][a-z0-9-]*$",
                options: .regularExpression
            ) != nil,
            kinds.contains(kind),
            ["progressive", "interlaced_tff", "interlaced_bff"]
                .contains(scanMode),
            sourceWidth > 0,
            sourceHeight > 0,
            targetWidth >= sourceWidth,
            targetHeight >= sourceHeight,
            targetWidth > sourceWidth || targetHeight > sourceHeight,
            !frames.isEmpty,
            !coverage.isEmpty,
            Set(coverage).count == coverage.count,
            Set(coverage).isSubset(of: allowedCoverage),
            checkpointBoundaries == Array(Set(checkpointBoundaries)).sorted(),
            checkpointBoundaries.allSatisfy({ $0 >= 0 && $0 < frames.count - 1 })
            else {
                throw ParityCaptureError.invalidContract("invalid case \(id)")
            }
            if kind == "pixel_interlaced_temporal", scanMode == "progressive" {
                throw ParityCaptureError.invalidContract(
                    "interlaced case \(id) has progressive scan mode"
                )
            }
            if kind != "pixel_interlaced_temporal", scanMode != "progressive" {
                throw ParityCaptureError.invalidContract(
                    "non-interlaced case \(id) has an interlaced scan mode"
                )
            }
            for frame in frames {
                guard frame.temporalResetReason == nil
                    || frame.temporalResetReason == "seek" else {
                    throw ParityCaptureError.invalidContract(
                        "case \(id) has an unsupported declared reset"
                    )
                }
            }
        }
    }

    private struct ParityRuntimeRecord: Codable, Equatable {
        let mode: String
        let runtimeID: String
        let releaseStatus: String
        let manifestSHA256: String
        let manifestFileSHA256: String
        let sourceRevision: String
        let builderSourceSHA256: String
        let trustRootConfigured: Bool
        let bindingVerified: Bool
    }

    private struct ParityArtifact: Codable, Equatable {
        let path: String
        let byteCount: Int
        let sha256: String
    }

    private struct ParityRunArtifacts: Codable, Equatable {
        let visible: ParityArtifact
        let semantics: ParityArtifact
        let checkpoints: ParityArtifact
        let resume: ParityArtifact
        let execution: ParityArtifact
    }

    private struct ParityScheduleRun: Codable, Equatable {
        let spatialSchedule: String
        let temporalSchedule: String
        let run: ParityRunArtifacts
    }

    private struct ParityBackendRunSet: Codable, Equatable {
        let canonical: ParityRunArtifacts
        let repeatRun: ParityRunArtifacts
        let schedules: [ParityScheduleRun]

        enum CodingKeys: String, CodingKey {
            case canonical
            case repeatRun = "repeat"
            case schedules
        }
    }

    private struct ParityCapturedCase: Codable, Equatable {
        let id: String
        let definition: ParityCaseDefinition
        let cpu: ParityBackendRunSet
        let metal: ParityBackendRunSet
        let metadata: ParityArtifact
    }

    private struct ParityCapture: Codable, Equatable {
        let schemaVersion: String
        let contractSHA256: String
        let captureSourceSHA256: String
        let sourceRevision: String
        let buildConfiguration: String
        let processRunID: String
        let evidenceRequestSHA256: String
        let packagedCandidateIdentity: MirmirPackagedCandidateIdentityV4
        let runtime: ParityRuntimeRecord
        let cases: [ParityCapturedCase]
    }

    private struct ParityArtifactManifest: Codable {
        let schemaVersion: String
        let artifacts: [ParityArtifact]
    }

    private struct ParityCaseMetadata: Codable {
        let id: String
        let sourceWidth: Int
        let sourceHeight: Int
        let targetWidth: Int
        let targetHeight: Int
        let horizontalUniquePhaseCount: Int
        let verticalUniquePhaseCount: Int
        let spatialPlanSHA256: String
        let kernelIRSHA256: String
        let cpuSourcePaddingByteCount: Int
        let cpuDestinationPaddingByteCount: Int
        let metalSourcePaddingByteCount: Int
        let metalDestinationPaddingByteCount: Int
        let cpuPaddingSentinelPreserved: Bool
        let metalPaddingSentinelPreserved: Bool
    }

    private struct ParityTimeRecord: Codable, Equatable {
        let value: Int64
        let timescale: Int32
        let flags: UInt32
        let epoch: Int64

        init(_ time: CMTime) throws {
            guard time.isNumeric, time.timescale > 0 else {
                throw ParityCaptureError.invalidFixture("non-numeric CMTime")
            }
            value = time.value
            timescale = time.timescale
            flags = time.flags.rawValue
            epoch = time.epoch
        }
    }

    private struct ParityInputTiming: Codable, Equatable {
        let presentationTime: ParityTimeRecord
        let duration: ParityTimeRecord
    }

    private struct ParityAttachmentDictionaryEntry: Encodable, Equatable {
        let key: String
        let value: ParityAttachmentPayload
    }

    private indirect enum ParityAttachmentPayload: Encodable, Equatable {
        case null
        case boolean(Bool)
        case signedInteger(String)
        case unsignedInteger(String)
        case realBits(String)
        case string(String)
        case date(String)
        case data(String)
        case array([ParityAttachmentPayload])
        case dictionary([ParityAttachmentDictionaryEntry])

        private enum CodingKeys: String, CodingKey { case kind, value }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .null:
                try container.encode("null", forKey: .kind)
                try container.encodeNil(forKey: .value)
            case .boolean(let value):
                try container.encode("boolean", forKey: .kind)
                try container.encode(value, forKey: .value)
            case .signedInteger(let value):
                try container.encode("signed_integer", forKey: .kind)
                try container.encode(value, forKey: .value)
            case .unsignedInteger(let value):
                try container.encode("unsigned_integer", forKey: .kind)
                try container.encode(value, forKey: .value)
            case .realBits(let value):
                try container.encode("real_ieee754_binary64", forKey: .kind)
                try container.encode(value, forKey: .value)
            case .string(let value):
                try container.encode("string", forKey: .kind)
                try container.encode(value, forKey: .value)
            case .date(let value):
                try container.encode("date_iso8601", forKey: .kind)
                try container.encode(value, forKey: .value)
            case .data(let value):
                try container.encode("data", forKey: .kind)
                try container.encode(value, forKey: .value)
            case .array(let value):
                try container.encode("array", forKey: .kind)
                try container.encode(value, forKey: .value)
            case .dictionary(let value):
                try container.encode("dictionary", forKey: .kind)
                try container.encode(value, forKey: .value)
            }
        }
    }

    private struct ParityAttachmentValue: Encodable, Equatable {
        let key: String
        let mode: String
        let value: ParityAttachmentPayload
    }

    private struct ParitySemanticOutput: Encodable, Equatable {
        let outputOrdinal: Int
        let presentationTime: ParityTimeRecord
        let duration: ParityTimeRecord
        let sourceField: String
        let cadenceID: String
        let classification: String?
        let historyGeneration: UInt64
        let temporalResetReason: String?
        let attachments: [ParityAttachmentValue]

        enum CodingKeys: String, CodingKey {
            case outputOrdinal
            case presentationTime
            case duration
            case sourceField
            case cadenceID
            case classification
            case historyGeneration
            case temporalResetReason
            case attachments
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(outputOrdinal, forKey: .outputOrdinal)
            try container.encode(presentationTime, forKey: .presentationTime)
            try container.encode(duration, forKey: .duration)
            try container.encode(sourceField, forKey: .sourceField)
            try container.encode(cadenceID, forKey: .cadenceID)
            if let classification {
                try container.encode(classification, forKey: .classification)
            } else {
                try container.encodeNil(forKey: .classification)
            }
            try container.encode(historyGeneration, forKey: .historyGeneration)
            try container.encodeIfPresent(
                temporalResetReason,
                forKey: .temporalResetReason
            )
            try container.encode(attachments, forKey: .attachments)
        }
    }

    private struct ParitySemanticInput: Encodable, Equatable {
        let inputOrdinal: Int
        let timing: ParityInputTiming
        let effectiveDominance: String?
        let sourceAttachments: [ParityAttachmentValue]
        let outputs: [ParitySemanticOutput]

        enum CodingKeys: String, CodingKey {
            case inputOrdinal
            case timing
            case effectiveDominance
            case sourceAttachments
            case outputs
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(inputOrdinal, forKey: .inputOrdinal)
            try container.encode(timing, forKey: .timing)
            if let effectiveDominance {
                try container.encode(effectiveDominance, forKey: .effectiveDominance)
            } else {
                try container.encodeNil(forKey: .effectiveDominance)
            }
            try container.encode(sourceAttachments, forKey: .sourceAttachments)
            try container.encode(outputs, forKey: .outputs)
        }
    }

    private struct ParitySemanticsDocument: Encodable, Equatable {
        let schemaVersion = "mirmir-ash-v4-canonical-semantics-v2"
        let caseID: String
        let inputs: [ParitySemanticInput]
    }

    private struct ParityCheckpointEntry: Encodable, Equatable {
        let inputOrdinal: Int
        let canonicalDataBase64: String
        let canonicalSHA256: String
    }

    private struct ParityCheckpointSet: Encodable, Equatable {
        let schemaVersion = "mirmir-ash-v4-checkpoint-set-v2"
        let caseID: String
        let entries: [ParityCheckpointEntry]
    }

    private struct ParityResumeEntry: Encodable, Equatable {
        let boundaryInputOrdinal: Int
        let uninterruptedVisibleBase64: String
        let resumedVisibleBase64: String
        let uninterruptedSemanticsBase64: String
        let resumedSemanticsBase64: String
        let uninterruptedFinalCheckpointBase64: String
        let resumedFinalCheckpointBase64: String
    }

    private struct ParityResumeSet: Encodable, Equatable {
        let schemaVersion = "mirmir-ash-v4-resume-set-v2"
        let caseID: String
        let entries: [ParityResumeEntry]
    }

    private struct ParityExecutionGrid: Codable, Equatable {
        let frameWidth: Int
        let frameHeight: Int
        let columns: Int
        let rows: Int
        let tileCount: Int
        let fullFrameSampleCount: Int

        init(_ grid: ASHTemporalTileGridV4) {
            frameWidth = grid.frameWidth
            frameHeight = grid.frameHeight
            columns = grid.columns
            rows = grid.rows
            tileCount = grid.tileCount
            fullFrameSampleCount = grid.fullFrameSampleCount
        }
    }

    private struct ParityAllocationContract: Codable, Equatable {
        let policyID: String
        let sourceFullFrameSampleCount: Int
        let sourceTileCount: Int
        let targetFullFrameSampleCount: Int
        let targetTileCount: Int
        let maximumRetainedTileSampleCount: Int
        let maximumOutputTileSampleCount: Int
        let fullFrameSampleArrayAllocationCap: Int

        init(_ value: ASHPreparedTiledAllocationContractV4) {
            policyID = value.policyID
            sourceFullFrameSampleCount = value.sourceFullFrameSampleCount
            sourceTileCount = value.sourceTileCount
            targetFullFrameSampleCount = value.targetFullFrameSampleCount
            targetTileCount = value.targetTileCount
            maximumRetainedTileSampleCount
                = value.maximumRetainedTileSampleCount
            maximumOutputTileSampleCount
                = value.maximumOutputTileSampleCount
            fullFrameSampleArrayAllocationCap
                = value.fullFrameSampleArrayAllocationCap
        }
    }

    private struct ParityBoundedRoute: Codable, Equatable {
        let usesBoundedTiledTemporalPath: Bool
        let tilePolicy: ParityTemporalTilePolicy
        let sourceGrid: ParityExecutionGrid
        let targetGrid: ParityExecutionGrid
        let allocationContract: ParityAllocationContract
    }

    private struct ParityExecutionEvidence: Encodable, Equatable {
        let schemaVersion = "mirmir-ash-v4-bounded-temporal-execution-v1"
        let caseID: String
        let backend: String
        let spatialSchedule: String
        let temporalSchedule: String
        let checkpointSchemaID: String
        let checkpointSHA256s: [String]
        let boundedRoute: ParityBoundedRoute?

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case caseID
            case backend
            case spatialSchedule
            case temporalSchedule
            case checkpointSchemaID
            case checkpointSHA256s
            case boundedRoute
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(caseID, forKey: .caseID)
            try container.encode(backend, forKey: .backend)
            try container.encode(spatialSchedule, forKey: .spatialSchedule)
            try container.encode(temporalSchedule, forKey: .temporalSchedule)
            try container.encode(checkpointSchemaID, forKey: .checkpointSchemaID)
            try container.encode(checkpointSHA256s, forKey: .checkpointSHA256s)
            if let boundedRoute {
                try container.encode(boundedRoute, forKey: .boundedRoute)
            } else {
                try container.encodeNil(forKey: .boundedRoute)
            }
        }
    }

    private struct ParityRunBytes: Equatable {
        let visible: Data
        let semantics: Data
        let checkpoints: Data
        let resume: Data
        let execution: Data
        let sourcePaddingByteCount: Int
        let destinationPaddingByteCount: Int
        let paddingSentinelPreserved: Bool

        func hasIdenticalPayload(to other: Self) -> Bool {
            visible == other.visible
                && semantics == other.semantics
                && checkpoints == other.checkpoints
                && resume == other.resume
                && sourcePaddingByteCount == other.sourcePaddingByteCount
                && destinationPaddingByteCount
                    == other.destinationPaddingByteCount
                && paddingSentinelPreserved == other.paddingSentinelPreserved
        }
    }

    private struct ParityProcessedPixelRange {
        let outputs: [CVPixelBuffer]
        let inputs: [ParitySemanticInput]
        let checkpoints: [ParityCheckpointEntry]
        let finalCheckpoint: Data
        let sourcePaddingByteCount: Int
        let destinationPaddingByteCount: Int
        let paddingSentinelPreserved: Bool
    }

    private static func captureCase(
        _ definition: ParityCaseDefinition,
        contract: ParityCaptureContract,
        runtime: ASHVerifiedRuntimeBundleV4,
        outputRoot: URL,
        directory: URL
    ) async throws -> ParityCapturedCase {
        let cpu = try await captureBackendRunSet(
            definition,
            backend: .cpu,
            schedulePairs: contract.schedulePairs,
            tilePolicy: definition.id == contract.boundedTemporalCaseID
                ? try contract.temporalTilePolicy.enginePolicy() : nil,
            runtime: runtime,
            outputRoot: outputRoot,
            directory: directory
        )
        let metal = try await captureBackendRunSet(
            definition,
            backend: .metal,
            schedulePairs: contract.schedulePairs,
            tilePolicy: definition.id == contract.boundedTemporalCaseID
                ? try contract.temporalTilePolicy.enginePolicy() : nil,
            runtime: runtime,
            outputRoot: outputRoot,
            directory: directory
        )
        guard cpu.bytes.hasIdenticalPayload(to: metal.bytes) else {
            throw ParityCaptureError.parityFailure(
                "\(definition.id) CPU/Metal run sets differ"
            )
        }

        let plan = try SpatialScalePlanV4(
            sourceWidth: definition.sourceWidth,
            sourceHeight: definition.sourceHeight,
            targetWidth: definition.targetWidth,
            targetHeight: definition.targetHeight,
            borderRule: .reflect101
        )
        let kernel = try FixedPointKernelIRV4(scalePlan: plan)
        let metadata = ParityCaseMetadata(
            id: definition.id,
            sourceWidth: definition.sourceWidth,
            sourceHeight: definition.sourceHeight,
            targetWidth: definition.targetWidth,
            targetHeight: definition.targetHeight,
            horizontalUniquePhaseCount: plan.horizontal.uniquePhases.count,
            verticalUniquePhaseCount: plan.vertical.uniquePhases.count,
            spatialPlanSHA256: sha256(try ASHCanonicalJSONV4.encode(plan)),
            kernelIRSHA256: sha256(try ASHCanonicalJSONV4.encode(kernel)),
            cpuSourcePaddingByteCount: cpu.bytes.sourcePaddingByteCount,
            cpuDestinationPaddingByteCount: cpu.bytes.destinationPaddingByteCount,
            metalSourcePaddingByteCount: metal.bytes.sourcePaddingByteCount,
            metalDestinationPaddingByteCount: metal.bytes.destinationPaddingByteCount,
            cpuPaddingSentinelPreserved: cpu.bytes.paddingSentinelPreserved,
            metalPaddingSentinelPreserved: metal.bytes.paddingSentinelPreserved
        )
        let metadataURL = directory.appendingPathComponent("case-metadata.json")
        try canonicalJSON(metadata).write(to: metadataURL, options: .atomic)
        return ParityCapturedCase(
            id: definition.id,
            definition: definition,
            cpu: cpu.artifacts,
            metal: metal.artifacts,
            metadata: try artifact(metadataURL, relativeTo: outputRoot)
        )
    }

    private struct CapturedBackendRunSet {
        let bytes: ParityRunBytes
        let artifacts: ParityBackendRunSet
    }

    private static func captureBackendRunSet(
        _ definition: ParityCaseDefinition,
        backend: FixedPointExecutionBackendV4,
        schedulePairs: [ParitySchedulePair],
        tilePolicy: ASHTemporalTilePolicyV4?,
        runtime: ASHVerifiedRuntimeBundleV4,
        outputRoot: URL,
        directory: URL
    ) async throws -> CapturedBackendRunSet {
        let name = backend.rawValue
        let canonicalBytes = try await execute(
            definition,
            backend: backend,
            schedule: .productionFullFrame,
            spatialScheduleID: "production_full_frame",
            temporalSchedule: .raster,
            tilePolicy: tilePolicy,
            runtime: runtime
        )
        let repeatBytes = try await execute(
            definition,
            backend: backend,
            schedule: .productionFullFrame,
            spatialScheduleID: "production_full_frame",
            temporalSchedule: .raster,
            tilePolicy: tilePolicy,
            runtime: runtime
        )
        guard canonicalBytes == repeatBytes else {
            throw ParityCaptureError.parityFailure(
                "\(definition.id)/\(name) repeat differs"
            )
        }
        let canonical = try writeRunArtifacts(
            canonicalBytes,
            prefix: "\(name)-canonical",
            outputRoot: outputRoot,
            directory: directory
        )
        let repeatRun = try writeRunArtifacts(
            repeatBytes,
            prefix: "\(name)-repeat",
            outputRoot: outputRoot,
            directory: directory
        )
        var scheduled: [ParityScheduleRun] = []
        for pair in schedulePairs {
            let bytes = try await execute(
                definition,
                backend: backend,
                schedule: try executionSchedule(pair.spatialSchedule),
                spatialScheduleID: pair.spatialSchedule,
                temporalSchedule: try temporalExecutionSchedule(
                    pair.temporalSchedule
                ),
                tilePolicy: tilePolicy,
                runtime: runtime
            )
            guard bytes.hasIdenticalPayload(to: canonicalBytes) else {
                throw ParityCaptureError.parityFailure(
                    "\(definition.id)/\(backend.rawValue)/" +
                        "\(pair.spatialSchedule)/" +
                        "\(pair.temporalSchedule) differs"
                )
            }
            scheduled.append(ParityScheduleRun(
                spatialSchedule: pair.spatialSchedule,
                temporalSchedule: pair.temporalSchedule,
                run: try writeRunArtifacts(
                    bytes,
                    prefix: "\(backend.rawValue)-schedule-" +
                        pair.spatialSchedule,
                    outputRoot: outputRoot,
                    directory: directory
                )
            ))
        }
        return CapturedBackendRunSet(
            bytes: canonicalBytes,
            artifacts: ParityBackendRunSet(
                canonical: canonical,
                repeatRun: repeatRun,
                schedules: scheduled
            )
        )
    }

    private static func writeRunArtifacts(
        _ bytes: ParityRunBytes,
        prefix: String,
        outputRoot: URL,
        directory: URL
    ) throws -> ParityRunArtifacts {
        func write(_ data: Data, suffix: String) throws -> ParityArtifact {
            let url = directory.appendingPathComponent("\(prefix)-\(suffix)")
            try data.write(to: url, options: .atomic)
            return try artifact(url, relativeTo: outputRoot)
        }
        return try ParityRunArtifacts(
            visible: write(bytes.visible, suffix: "visible.bin"),
            semantics: write(bytes.semantics, suffix: "semantics.json"),
            checkpoints: write(bytes.checkpoints, suffix: "checkpoints.json"),
            resume: write(bytes.resume, suffix: "resume.json"),
            execution: write(bytes.execution, suffix: "execution.json")
        )
    }

    private static func executionSchedule(
        _ value: String
    ) throws -> FixedPointExecutionScheduleV4 {
        switch value {
        case "row_major": .qualificationRowMajor3x2
        case "reverse": .qualificationReverse3x2
        case "even_then_odd": .qualificationEvenOdd3x2
        default:
            throw ParityCaptureError.invalidContract("unknown schedule \(value)")
        }
    }

    private static func temporalExecutionSchedule(
        _ value: String
    ) throws -> ASHTemporalTileExecutionScheduleV4 {
        switch value {
        case "raster": .raster
        case "reverse_raster": .reverseRaster
        case "even_then_odd": .evenThenOdd
        default:
            throw ParityCaptureError.invalidContract(
                "unknown temporal schedule \(value)"
            )
        }
    }

    private static func execute(
        _ definition: ParityCaseDefinition,
        backend: FixedPointExecutionBackendV4,
        schedule: FixedPointExecutionScheduleV4,
        spatialScheduleID: String,
        temporalSchedule: ASHTemporalTileExecutionScheduleV4,
        tilePolicy: ASHTemporalTilePolicyV4?,
        runtime: ASHVerifiedRuntimeBundleV4
    ) async throws -> ParityRunBytes {
        if definition.kind == "alpha_spatial" {
            return try await executeAlpha(
                definition,
                backend: backend,
                schedule: schedule,
                spatialScheduleID: spatialScheduleID,
                temporalSchedule: temporalSchedule,
                runtime: runtime
            )
        }
        return try await executePixel(
            definition,
            backend: backend,
            schedule: schedule,
            spatialScheduleID: spatialScheduleID,
            temporalSchedule: temporalSchedule,
            tilePolicy: tilePolicy,
            runtime: runtime
        )
    }

    private static func executePixel(
        _ definition: ParityCaseDefinition,
        backend: FixedPointExecutionBackendV4,
        schedule: FixedPointExecutionScheduleV4,
        spatialScheduleID: String,
        temporalSchedule: ASHTemporalTileExecutionScheduleV4,
        tilePolicy: ASHTemporalTilePolicyV4?,
        runtime: ASHVerifiedRuntimeBundleV4
    ) async throws -> ParityRunBytes {
        let configuration = try preparedConfiguration(definition, backend: backend)
        let planSHA = ASHSHA256V4(
            rawData: Data("parity-v2:\(definition.id)".utf8)
        )
        let prepared = try makePrepared(
            configuration: configuration,
            schedule: schedule,
            tilePolicy: tilePolicy,
            temporalSchedule: temporalSchedule,
            runtime: runtime
        )
        let complete = try await processPixelFrames(
            definition,
            ordinals: Array(definition.frames.indices),
            prepared: prepared,
            configuration: configuration,
            runtime: runtime,
            planSHA: planSHA,
            backend: backend
        )
        let visible = try visiblePixelSequence(
            complete.outputs,
            storage: configuration.storage
        )
        let semantics = try canonicalJSON(ParitySemanticsDocument(
            caseID: definition.id,
            inputs: complete.inputs
        ))
        let checkpoints = try canonicalJSON(ParityCheckpointSet(
            caseID: definition.id,
            entries: complete.checkpoints
        ))
        var resumeEntries: [ParityResumeEntry] = []
        for boundary in definition.checkpointBoundaries {
            let prefixPrepared = try makePrepared(
                configuration: configuration,
                schedule: schedule,
                tilePolicy: tilePolicy,
                temporalSchedule: temporalSchedule,
                runtime: runtime
            )
            let prefix = try await processPixelFrames(
                definition,
                ordinals: Array(0...boundary),
                prepared: prefixPrepared,
                configuration: configuration,
                runtime: runtime,
                planSHA: planSHA,
                backend: backend
            )
            let resumedPrepared = try makePrepared(
                configuration: configuration,
                schedule: schedule,
                tilePolicy: tilePolicy,
                temporalSchedule: temporalSchedule,
                runtime: runtime
            )
            try await resumedPrepared.restoreTemporalCheckpoint(
                prefix.finalCheckpoint,
                planSHA256: planSHA
            )
            let suffix = try await processPixelFrames(
                definition,
                ordinals: Array((boundary + 1)..<definition.frames.count),
                prepared: resumedPrepared,
                configuration: configuration,
                runtime: runtime,
                planSHA: planSHA,
                backend: backend
            )
            let resumedVisible = try visiblePixelSequence(
                prefix.outputs + suffix.outputs,
                storage: configuration.storage
            )
            let resumedSemantics = try canonicalJSON(ParitySemanticsDocument(
                caseID: definition.id,
                inputs: prefix.inputs + suffix.inputs
            ))
            guard visible == resumedVisible,
                  semantics == resumedSemantics,
                  complete.finalCheckpoint == suffix.finalCheckpoint else {
                throw ParityCaptureError.parityFailure(
                    "\(definition.id) checkpoint/resume differs at \(boundary)"
                )
            }
            resumeEntries.append(ParityResumeEntry(
                boundaryInputOrdinal: boundary,
                uninterruptedVisibleBase64: visible.base64EncodedString(),
                resumedVisibleBase64: resumedVisible.base64EncodedString(),
                uninterruptedSemanticsBase64: semantics.base64EncodedString(),
                resumedSemanticsBase64: resumedSemantics.base64EncodedString(),
                uninterruptedFinalCheckpointBase64:
                    complete.finalCheckpoint.base64EncodedString(),
                resumedFinalCheckpointBase64:
                    suffix.finalCheckpoint.base64EncodedString()
            ))
        }
        let resume = try canonicalJSON(ParityResumeSet(
            caseID: definition.id,
            entries: resumeEntries
        ))
        let execution = try canonicalJSON(ParityExecutionEvidence(
            caseID: definition.id,
            backend: backend.rawValue,
            spatialSchedule: spatialScheduleID,
            temporalSchedule: temporalSchedule.rawValue,
            checkpointSchemaID: tilePolicy == nil
                ? ASHPreparedTemporalCheckpointV4.currentSchemaID
                : ASHPreparedTiledTemporalCheckpointV4.currentSchemaID,
            checkpointSHA256s: complete.checkpoints.map(\.canonicalSHA256),
            boundedRoute: try boundedRouteEvidence(
                prepared: prepared,
                definition: definition,
                policy: tilePolicy
            )
        ))
        return ParityRunBytes(
            visible: visible,
            semantics: semantics,
            checkpoints: checkpoints,
            resume: resume,
            execution: execution,
            sourcePaddingByteCount: complete.sourcePaddingByteCount,
            destinationPaddingByteCount: complete.destinationPaddingByteCount,
            paddingSentinelPreserved: complete.paddingSentinelPreserved
        )
    }

    private static func preparedConfiguration(
        _ definition: ParityCaseDefinition,
        backend: FixedPointExecutionBackendV4
    ) throws -> DeterministicPreparedConfigurationV4 {
        let scanMode: DeterministicScanModeV4
        switch definition.scanMode {
        case "progressive": scanMode = .progressive
        case "interlaced_tff": scanMode = .interlaced(.topFieldFirst)
        case "interlaced_bff": scanMode = .interlaced(.bottomFieldFirst)
        default:
            throw ParityCaptureError.invalidContract("invalid scan mode")
        }
        return DeterministicPreparedConfigurationV4(
            backendID: backend == .cpu
                ? .mirmirDeterministicCPU : .mirmirDeterministicMetal,
            executionBackend: backend,
            storage: try pixelStorage(definition.storage),
            sourceWidth: definition.sourceWidth,
            sourceHeight: definition.sourceHeight,
            targetWidth: definition.targetWidth,
            targetHeight: definition.targetHeight,
            scanMode: scanMode
        )
    }

    private static func makePrepared(
        configuration: DeterministicPreparedConfigurationV4,
        schedule: FixedPointExecutionScheduleV4,
        tilePolicy: ASHTemporalTilePolicyV4?,
        temporalSchedule: ASHTemporalTileExecutionScheduleV4,
        runtime: ASHVerifiedRuntimeBundleV4
    ) throws -> PreparedDeterministicV4Upscaler {
        let device = configuration.executionBackend == .metal
            ? MTLCreateSystemDefaultDevice() : nil
        let library = try device.map {
            try ASHP06MetalLibraryFactoryV4.makeLibrary(
                runtime: runtime,
                device: $0
            )
        }
        let prepared = try PreparedDeterministicV4Upscaler(
            configuration: configuration,
            runtime: runtime,
            executionSchedule: schedule,
            temporalTilePolicy: tilePolicy,
            temporalTileExecutionSchedule: temporalSchedule,
            metalDevice: device,
            metalLibrary: library
        )
        guard prepared.temporalTileExecutionSchedule == temporalSchedule,
              prepared.temporalTilePolicy == tilePolicy else {
            throw ParityCaptureError.invalidFixture(
                "prepared temporal route differs from requested route"
            )
        }
        if tilePolicy == nil {
            guard !prepared.usesBoundedTiledTemporalPath,
                  prepared.tiledAllocationContract == nil else {
                throw ParityCaptureError.invalidFixture(
                    "unforced case selected the bounded tiled route"
                )
            }
        } else {
            guard prepared.usesBoundedTiledTemporalPath,
                  prepared.tiledAllocationContract != nil else {
                throw ParityCaptureError.invalidFixture(
                    "forced case did not select the bounded tiled route"
                )
            }
        }
        return prepared
    }

    private static func boundedRouteEvidence(
        prepared: PreparedDeterministicV4Upscaler,
        definition: ParityCaseDefinition,
        policy: ASHTemporalTilePolicyV4?
    ) throws -> ParityBoundedRoute? {
        guard let policy else {
            guard !prepared.usesBoundedTiledTemporalPath,
                  prepared.tiledAllocationContract == nil else {
                throw ParityCaptureError.invalidFixture(
                    "unexpected bounded route diagnostics"
                )
            }
            return nil
        }
        let sourceGrid = try ASHTemporalTileGridV4(
            frameWidth: definition.sourceWidth,
            frameHeight: definition.sourceHeight,
            policy: policy
        )
        let targetGrid = try ASHTemporalTileGridV4(
            frameWidth: definition.targetWidth,
            frameHeight: definition.targetHeight,
            policy: policy
        )
        guard sourceGrid.tileCount > 1,
              targetGrid.tileCount > 1,
              prepared.usesBoundedTiledTemporalPath,
              prepared.temporalTilePolicy == policy,
              let allocation = prepared.tiledAllocationContract,
              allocation.policyID == policy.policyID,
              allocation.sourceFullFrameSampleCount
                == sourceGrid.fullFrameSampleCount,
              allocation.sourceTileCount == sourceGrid.tileCount,
              allocation.targetFullFrameSampleCount
                == targetGrid.fullFrameSampleCount,
              allocation.targetTileCount == targetGrid.tileCount,
              allocation.maximumRetainedTileSampleCount
                == policy.maximumRetainedTileSampleCount,
              allocation.maximumOutputTileSampleCount
                == policy.tileWidth * policy.tileHeight,
              allocation.fullFrameSampleArrayAllocationCap == 0 else {
            throw ParityCaptureError.invalidFixture(
                "bounded route allocation diagnostics differ"
            )
        }
        return ParityBoundedRoute(
            usesBoundedTiledTemporalPath: true,
            tilePolicy: .qualification,
            sourceGrid: ParityExecutionGrid(sourceGrid),
            targetGrid: ParityExecutionGrid(targetGrid),
            allocationContract: ParityAllocationContract(allocation)
        )
    }

    private static func processPixelFrames(
        _ definition: ParityCaseDefinition,
        ordinals: [Int],
        prepared: PreparedDeterministicV4Upscaler,
        configuration: DeterministicPreparedConfigurationV4,
        runtime: ASHVerifiedRuntimeBundleV4,
        planSHA: ASHSHA256V4,
        backend: FixedPointExecutionBackendV4
    ) async throws -> ParityProcessedPixelRange {
        var buffers: [CVPixelBuffer] = []
        var semanticInputs: [ParitySemanticInput] = []
        var checkpointEntries: [ParityCheckpointEntry] = []
        var finalCheckpoint = Data()
        var sourcePaddingByteCount = 0
        var destinationPaddingByteCount = 0
        var paddingPreserved = true
        for ordinal in ordinals {
            let frame = definition.frames[ordinal]
            let source = try makePixelBuffer(
                storage: configuration.storage,
                width: definition.sourceWidth,
                height: definition.sourceHeight,
                metalCompatible: backend == .metal
            )
            try fillAllStorageBytes(source, sentinel: 0xA7)
            try PixelBufferSignalCodecV4.write(
                makeSignalFrame(
                    storage: configuration.storage,
                    width: definition.sourceWidth,
                    height: definition.sourceHeight,
                    frame: frame
                ),
                to: source
            )
            try installPixelAttachments(
                on: source,
                storage: configuration.storage,
                frame: frame
            )
            let sourceAttachments = try frameAttachments(source)
            let sourcePaddingBefore = try paddingBytes(
                source,
                storage: configuration.storage
            )
            let outputCount = prepared.maximumOutputFramesPerInput
            var destinations: [FramePixelBuffer] = []
            for _ in 0..<outputCount {
                let destination = try makePixelBuffer(
                    storage: configuration.storage,
                    width: definition.targetWidth,
                    height: definition.targetHeight,
                    metalCompatible: backend == .metal
                )
                try fillAllStorageBytes(destination, sentinel: 0xD3)
                destinations.append(FramePixelBuffer(destination))
            }
            let presentationTime = CMTime(
                value: frame.presentationTime.value,
                timescale: frame.presentationTime.timescale
            )
            let duration = CMTime(
                value: frame.duration.value,
                timescale: frame.duration.timescale
            )
            let outputs = try await prepared.processTemporal(
                source: FramePixelBuffer(source),
                destinations: destinations,
                timing: FrameTiming(
                    frameIndex: ordinal,
                    presentationTime: presentationTime,
                    duration: duration,
                    temporalResetReason: try temporalResetReason(
                        frame.temporalResetReason
                    )
                )
            )
            finalCheckpoint = try await prepared.makeTemporalCheckpoint(
                planSHA256: planSHA,
                lastCompletedInputOrdinal: Int64(ordinal)
            )
            let checkpointGeneration: UInt64
            let checkpointCadenceID: String
            let classification: String?
            if let tilePolicy = prepared.temporalTilePolicy {
                let checkpoint = try ASHPreparedTiledTemporalCheckpointV4
                    .decodeCanonical(
                        finalCheckpoint,
                        expectedPlanSHA256: planSHA,
                        expectedRuntimeManifestSHA256: runtime.manifestSHA256,
                        expectedFormatIdentity: checkpointFormatIdentity(
                            runtime: runtime,
                            configuration: configuration
                        ),
                        expectedTilePolicy: tilePolicy
                    )
                guard try checkpoint.canonicalData == finalCheckpoint,
                      let latest = checkpoint.history.entries.last?.frame,
                      latest.grid.tileCount > 1,
                      checkpoint.previousSourceTiledFrame.grid.tileCount > 1
                else {
                    throw ParityCaptureError.invalidFixture(
                        "noncanonical or single-tile bounded checkpoint"
                    )
                }
                checkpointGeneration = checkpoint.history.generation
                checkpointCadenceID = latest.cadenceID
                classification = checkpoint.fieldCadenceState?
                    .classification.rawValue
            } else {
                let checkpoint = try ASHPreparedTemporalCheckpointV4
                    .decodeCanonical(
                        finalCheckpoint,
                        expectedPlanSHA256: planSHA,
                        expectedRuntimeManifestSHA256: runtime.manifestSHA256,
                        expectedFormatIdentity: checkpointFormatIdentity(
                            runtime: runtime,
                            configuration: configuration
                        )
                    )
                guard try checkpoint.canonicalData == finalCheckpoint,
                      let latest = checkpoint.history.frames.last else {
                    throw ParityCaptureError.invalidFixture(
                        "noncanonical checkpoint"
                    )
                }
                checkpointGeneration = checkpoint.history.generation
                checkpointCadenceID = latest.cadenceID
                classification = checkpoint.fieldCadenceState?
                    .classification.rawValue
            }
            let expectedOutputStart = definition.scanMode == "progressive"
                ? ordinal : ordinal * 2
            let semantics = try outputs.enumerated().map { index, output in
                let priorGeneration = index == 0
                    ? nil : outputs[index - 1].temporalGeneration
                let isFinalOutput = index == outputs.count - 1
                guard output.temporalGeneration > 0,
                      output.temporalGeneration <= checkpointGeneration,
                      (!isFinalOutput
                        || output.temporalGeneration
                            == checkpointGeneration),
                      priorGeneration.map({
                        output.temporalGeneration >= $0
                            && output.temporalGeneration - $0 <= 1
                      }) ?? true,
                      output.cadenceID == checkpointCadenceID,
                      frame.temporalResetReason == nil
                        || output.temporalResetReason?.rawValue
                            == frame.temporalResetReason else {
                    throw ParityCaptureError.invalidFixture(
                        "typed output semantics differ from checkpoint " +
                        "case=\(definition.id) backend=\(backend.rawValue) " +
                        "input=\(ordinal) output=\(index) " +
                        "outputGeneration=\(output.temporalGeneration) " +
                        "checkpointGeneration=\(checkpointGeneration) " +
                        "outputCadence=\(output.cadenceID) " +
                        "checkpointCadence=\(checkpointCadenceID)"
                    )
                }
                return ParitySemanticOutput(
                    outputOrdinal: expectedOutputStart + index,
                    presentationTime: try ParityTimeRecord(output.presentationTime),
                    duration: try ParityTimeRecord(output.duration),
                    sourceField: output.sourceField.rawValue,
                    cadenceID: output.cadenceID,
                    classification: classification,
                    historyGeneration: output.temporalGeneration,
                    temporalResetReason: output.temporalResetReason?.rawValue,
                    attachments: try frameAttachments(output.pixelBuffer.value)
                )
            }
            semanticInputs.append(ParitySemanticInput(
                inputOrdinal: ordinal,
                timing: ParityInputTiming(
                    presentationTime: try ParityTimeRecord(presentationTime),
                    duration: try ParityTimeRecord(duration)
                ),
                effectiveDominance: effectiveDominance(frame.fieldDetail),
                sourceAttachments: sourceAttachments,
                outputs: semantics
            ))
            checkpointEntries.append(ParityCheckpointEntry(
                inputOrdinal: ordinal,
                canonicalDataBase64: finalCheckpoint.base64EncodedString(),
                canonicalSHA256: sha256(finalCheckpoint)
            ))
            buffers.append(contentsOf: outputs.map(\.pixelBuffer.value))
            sourcePaddingByteCount = max(
                sourcePaddingByteCount,
                try paddingByteCount(source, storage: configuration.storage)
            )
            let sourcePaddingAfter = try paddingBytes(
                source,
                storage: configuration.storage
            )
            paddingPreserved = paddingPreserved
                && sourcePaddingBefore == sourcePaddingAfter
            for destination in destinations {
                destinationPaddingByteCount = max(
                    destinationPaddingByteCount,
                    try paddingByteCount(
                        destination.value,
                        storage: configuration.storage
                    )
                )
                let destinationPadding = try paddingBytes(
                    destination.value,
                    storage: configuration.storage
                )
                paddingPreserved = paddingPreserved
                    && destinationPadding.allSatisfy { $0 == 0xD3 }
            }
        }
        guard !finalCheckpoint.isEmpty else {
            throw ParityCaptureError.invalidFixture("empty checkpoint range")
        }
        return ParityProcessedPixelRange(
            outputs: buffers,
            inputs: semanticInputs,
            checkpoints: checkpointEntries,
            finalCheckpoint: finalCheckpoint,
            sourcePaddingByteCount: sourcePaddingByteCount,
            destinationPaddingByteCount: destinationPaddingByteCount,
            paddingSentinelPreserved: paddingPreserved
        )
    }

    private static func temporalResetReason(
        _ value: String?
    ) throws -> ASHTemporalResetReasonV4? {
        guard let value else { return nil }
        guard value == ASHTemporalResetReasonV4.seek.rawValue else {
            throw ParityCaptureError.invalidContract(
                "unsupported declared temporal reset \(value)"
            )
        }
        return .seek
    }

    private static func effectiveDominance(_ detail: String) -> String? {
        switch detail {
        case "temporal_top_first": "top_field_first"
        case "temporal_bottom_first": "bottom_field_first"
        default: nil
        }
    }

    private static func executeAlpha(
        _ definition: ParityCaseDefinition,
        backend: FixedPointExecutionBackendV4,
        schedule: FixedPointExecutionScheduleV4,
        spatialScheduleID: String,
        temporalSchedule: ASHTemporalTileExecutionScheduleV4,
        runtime: ASHVerifiedRuntimeBundleV4
    ) async throws -> ParityRunBytes {
        let layout = try alphaLayout(definition.storage)
        let association = try alphaAssociation(definition.association)
        let frame = definition.frames[0]
        let source = try makePackedBuffer(
            layout: layout,
            width: definition.sourceWidth,
            height: definition.sourceHeight,
            padding: 13,
            sentinel: 0xA7
        )
        let destination = try makePackedBuffer(
            layout: layout,
            width: definition.targetWidth,
            height: definition.targetHeight,
            padding: 17,
            sentinel: 0xD3
        )
        try Alpha4444PixelBufferAccessV4.write(
            alphaSamples(
                width: definition.sourceWidth,
                height: definition.sourceHeight,
                maximum: layout.signalBitDepth == 8 ? 255 : 65_535,
                association: association
            ),
            to: source,
            layout: layout
        )
        installAlphaAssociation(association, on: source)
        installNestedAttachment(on: source)
        let sourceAttachments = try frameAttachments(source)
        let sourcePaddingBefore = try packedPaddingBytes(source, layout: layout)
        let device = backend == .metal ? MTLCreateSystemDefaultDevice() : nil
        let library = try device.map {
            try ASHP06MetalLibraryFactoryV4.makeLibrary(
                runtime: runtime,
                device: $0
            )
        }
        let scaler = try Alpha4444FixedPointScalerV4(
            backend: backend == .cpu ? .cpu : .metal,
            layout: layout,
            sourceAssociation: association,
            destinationAssociation: association,
            zeroAlphaPolicy: .clearColor,
            sourceWidth: definition.sourceWidth,
            sourceHeight: definition.sourceHeight,
            targetWidth: definition.targetWidth,
            targetHeight: definition.targetHeight,
            borderRule: .reflect101,
            executionSchedule: schedule,
            metalDevice: device,
            metalLibrary: library
        )
        try await scaler.process(source: source, destination: destination)
        let presentation = CMTime(
            value: frame.presentationTime.value,
            timescale: frame.presentationTime.timescale
        )
        let duration = CMTime(
            value: frame.duration.value,
            timescale: frame.duration.timescale
        )
        let semantics = try canonicalJSON(ParitySemanticsDocument(
            caseID: definition.id,
            inputs: [ParitySemanticInput(
                inputOrdinal: 0,
                timing: ParityInputTiming(
                    presentationTime: try ParityTimeRecord(presentation),
                    duration: try ParityTimeRecord(duration)
                ),
                effectiveDominance: nil,
                sourceAttachments: sourceAttachments,
                outputs: [ParitySemanticOutput(
                    outputOrdinal: 0,
                    presentationTime: try ParityTimeRecord(presentation),
                    duration: try ParityTimeRecord(duration),
                    sourceField: "progressive",
                    cadenceID: "progressive",
                    classification: nil,
                    historyGeneration: 1,
                    temporalResetReason: nil,
                    attachments: try frameAttachments(destination)
                )]
            )]
        ))
        let checkpoints = try canonicalJSON(ParityCheckpointSet(
            caseID: definition.id,
            entries: []
        ))
        let resume = try canonicalJSON(ParityResumeSet(
            caseID: definition.id,
            entries: []
        ))
        let execution = try canonicalJSON(ParityExecutionEvidence(
            caseID: definition.id,
            backend: backend.rawValue,
            spatialSchedule: spatialScheduleID,
            temporalSchedule: temporalSchedule.rawValue,
            checkpointSchemaID: "none",
            checkpointSHA256s: [],
            boundedRoute: nil
        ))
        let sourcePadding = try packedPaddingBytes(source, layout: layout)
        let destinationPadding = try packedPaddingBytes(destination, layout: layout)
        return ParityRunBytes(
            visible: try visiblePackedSequence([destination], layout: layout),
            semantics: semantics,
            checkpoints: checkpoints,
            resume: resume,
            execution: execution,
            sourcePaddingByteCount: sourcePadding.count,
            destinationPaddingByteCount: destinationPadding.count,
            paddingSentinelPreserved: sourcePadding == sourcePaddingBefore
                && destinationPadding.allSatisfy { $0 == 0xD3 }
        )
    }

    private static func loadRuntime(mode: String) throws -> ASHVerifiedRuntimeBundleV4 {
        guard mode == "production" else {
            throw ParityCaptureError.invalidEnvironment(
                "the packaged observer admits only production runtime mode"
            )
        }
        guard ASHProductionP06TrustRootV4.isConfigured else {
            throw ParityCaptureError.invalidFixture(
                "the production P06 trust root is not configured"
            )
        }
        return try ASHP06RuntimeProviderV4.production(bundle: .main).load()
    }

    private static func makeRuntimeRecord(
        _ runtime: ASHVerifiedRuntimeBundleV4,
        mode: String,
        expected: ParityReleaseRuntimeContract
    ) throws -> ParityRuntimeRecord {
        let manifestBytes: Data
        if mode == "production" {
            manifestBytes = try Data(contentsOf: runtime.bundleURL
                .appendingPathComponent(ASHRuntimeManifestV4.fileName))
        } else {
            manifestBytes = try ASHCanonicalJSONV4.encode(runtime.manifest)
        }
        guard runtime.manifest.runtimeID == expected.runtimeID else {
            throw ParityCaptureError.invalidFixture("runtime identity mismatch")
        }
        if mode == "production" {
            guard runtime.manifest.releaseStatus.rawValue
                    == expected.requiredReleaseStatus,
                  runtime.bundleURL.lastPathComponent == "ASH-P06.bundle",
                  ASHProductionP06TrustRootV4.manifestSHA256
                    == runtime.manifestSHA256,
                  ASHProductionP06TrustRootV4.sourceRevision
                    == runtime.manifest.provenance.sourceRevision,
                  ASHProductionP06TrustRootV4.builderSourceSHA256
                    == runtime.manifest.provenance.builderSourceSHA256 else {
                throw ParityCaptureError.invalidFixture(
                    "production runtime is not bound to its code trust root"
                )
            }
        }
        return ParityRuntimeRecord(
            mode: mode,
            runtimeID: runtime.manifest.runtimeID,
            releaseStatus: runtime.manifest.releaseStatus.rawValue,
            manifestSHA256: runtime.manifestSHA256.rawValue,
            manifestFileSHA256: sha256(manifestBytes),
            sourceRevision: runtime.manifest.provenance.sourceRevision,
            builderSourceSHA256:
                runtime.manifest.provenance.builderSourceSHA256.rawValue,
            trustRootConfigured: mode == "production"
                ? ASHProductionP06TrustRootV4.isConfigured : false,
            bindingVerified: true
        )
    }

    private static func pixelStorage(_ value: String) throws -> PixelStorageV4 {
        switch value {
        case "nv12_video_range_8": .nv12VideoRange8Bit
        case "nv12_full_range_8": .nv12FullRange8Bit
        case "p010_video_range_10": .p010VideoRange10Bit
        case "p010_full_range_10": .p010FullRange10Bit
        default:
            throw ParityCaptureError.invalidContract("unsupported storage \(value)")
        }
    }

    private static func alphaLayout(
        _ value: String
    ) throws -> Alpha4444PackedLayoutV4 {
        switch value {
        case "bgra8": .bgra8
        case "argb16_big_endian": .argb16BigEndian
        default:
            throw ParityCaptureError.invalidContract("unsupported alpha layout")
        }
    }

    private static func alphaAssociation(_ value: String) throws -> AlphaAssociationV4 {
        switch value {
        case "straight": .straight
        case "premultiplied": .premultiplied
        default:
            throw ParityCaptureError.invalidContract("unsupported association")
        }
    }

    private static func makePixelBuffer(
        storage: PixelStorageV4,
        width: Int,
        height: Int,
        metalCompatible: Bool
    ) throws -> CVPixelBuffer {
        try PixelBufferSignalCodecV4.makeBuffer(
            storage: storage,
            width: width,
            height: height,
            metalCompatible: metalCompatible
        )
    }

    private static func makeSignalFrame(
        storage: PixelStorageV4,
        width: Int,
        height: Int,
        frame: ParityFrameDefinition
    ) -> PixelBufferSignalFrameV4 {
        let layout = PixelLayoutV4(storage: storage)
        let planes = layout.planes.enumerated().map { planeIndex, plane in
            let planeWidth = try! plane.width(forFrameWidth: width)
            let planeHeight = try! plane.height(forFrameHeight: height)
            var samples: [UInt16] = []
            samples.reserveCapacity(
                planeWidth * planeHeight * plane.componentsPerElement
            )
            for y in 0..<planeHeight {
                for x in 0..<planeWidth {
                    for component in 0..<plane.componentsPerElement {
                        samples.append(patternValue(
                            frame: frame,
                            x: x,
                            y: y,
                            width: planeWidth,
                            plane: planeIndex,
                            component: component,
                            bounds: plane.signalCodeBounds[component]
                        ))
                    }
                }
            }
            return try! PixelBufferSignalPlaneV4(
                width: planeWidth,
                height: planeHeight,
                componentsPerElement: plane.componentsPerElement,
                componentBounds: plane.signalCodeBounds,
                samples: samples
            )
        }
        return PixelBufferSignalFrameV4(
            storage: storage,
            width: width,
            height: height,
            planes: planes
        )
    }

    private static func patternValue(
        frame: ParityFrameDefinition,
        x: Int,
        y: Int,
        width: Int,
        plane: Int,
        component: Int,
        bounds: PixelCodeBoundsV4
    ) -> UInt16 {
        let low = Int(bounds.minimum)
        let high = Int(bounds.maximum)
        let span = max(1, high - low)
        let value: Int
        switch frame.pattern {
        case "moving_edge_0", "moving_edge_1", "moving_edge_2":
            let shift = ["moving_edge_0": 0, "moving_edge_1": 1][frame.pattern]
                ?? 2
            let edge = max(1, width / 2 + shift)
            let base = x < edge ? low + span / 6 : high - span / 7
            value = base + ((y * 7 + component * 11 + plane * 13)
                % max(1, span / 10))
        case "scene_cut_white":
            value = high - ((x + y + component) % max(1, span / 32))
        case "rational_detail":
            value = low + ((x * 97 + y * 53 + component * 29 + plane * 71)
                % (span + 1))
        case "periodic_phase_0", "periodic_phase_1":
            let phase = frame.pattern == "periodic_phase_0" ? 0 : 1
            let stripe = ((x + phase) % 4) < 2 ? 0 : 1
            let cross = ((y + phase) % 4) < 2 ? 0 : 1
            let band = stripe ^ cross
            // Keep the translated periodic texture below the scene-cut
            // threshold so this case exercises ambiguous motion/history.
            value = low + (band == 0 ? (span * 7) / 16 : (span * 9) / 16)
                + ((component * 7 + plane * 11) % max(1, span / 32))
        case "field_pair":
            let token = y.isMultiple(of: 2)
                ? (frame.topToken ?? 0) : (frame.bottomToken ?? 0)
            value = low + ((token * 977 + x * 31 + component * 19 + plane * 43)
                % (span + 1))
        default:
            value = low + span / 2
        }
        return UInt16(min(high, max(low, value)))
    }

    private static func installPixelAttachments(
        on buffer: CVPixelBuffer,
        storage: PixelStorageV4,
        frame: ParityFrameDefinition
    ) throws {
        let hdr = frame.hdrProfile != "none"
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            hdr ? kCVImageBufferColorPrimaries_ITU_R_2020
                : kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        let transfer: CFString
        switch frame.hdrProfile {
        case "hlg_static_dynamic":
            transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case "pq_static", "pq_static_dynamic":
            transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        default:
            transfer = kCVImageBufferTransferFunction_ITU_R_709_2
        }
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            transfer,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020
                : kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        if frame.fieldDetail != "none" {
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferChromaLocationBottomFieldKey,
                kCVImageBufferChromaLocation_Center,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferFieldCountKey,
                NSNumber(value: 2),
                .shouldPropagate
            )
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferFieldDetailKey,
                frame.fieldDetail == "temporal_top_first"
                    ? kCVImageBufferFieldDetailTemporalTopFirst
                    : kCVImageBufferFieldDetailTemporalBottomFirst,
                .shouldPropagate
            )
        }
        if hdr {
            let metadata = try parityStaticHDRMetadata()
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferMasteringDisplayColorVolumeKey,
                metadata.masteringDisplayColorVolume!.payload as CFData,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferContentLightLevelInfoKey,
                metadata.contentLightLevelInfo!.payload as CFData,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferAmbientViewingEnvironmentKey,
                metadata.ambientViewingEnvironment!.payload as CFData,
                .shouldPropagate
            )
        }
        if frame.hdrProfile.hasSuffix("_dynamic") {
            CVBufferSetAttachment(
                buffer,
                kCMSampleAttachmentKey_HDR10PlusPerFrameData,
                Data([
                    0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x01
                ]) as CFData,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                buffer,
                kCMSampleAttachmentKey_PostDecodeProcessingMetadata,
                ["mode": "fixture", "strength": 7] as CFDictionary,
                .shouldPropagate
            )
        }
        installNestedAttachment(on: buffer)
        _ = storage
    }

    private static func parityStaticHDRMetadata() throws -> HDRStaticMetadataV4 {
        let primaries = [
            try HDRChromaticityV4(x: 8_500, y: 39_850, label: "green"),
            try HDRChromaticityV4(x: 6_550, y: 2_300, label: "blue"),
            try HDRChromaticityV4(x: 35_400, y: 14_600, label: "red")
        ]
        return HDRStaticMetadataV4(
            masteringDisplayColorVolume: try MasteringDisplayColorVolumeV4(
                displayPrimaries: primaries,
                whitePoint: HDRChromaticityV4(
                    x: 15_635,
                    y: 16_450,
                    label: "white"
                ),
                maximumDisplayMasteringLuminance: 10_000_000,
                minimumDisplayMasteringLuminance: 50
            ),
            contentLightLevelInfo: try ContentLightLevelInfoV4(
                maximumContentLightLevel: 1_000,
                maximumFrameAverageLightLevel: 400
            ),
            ambientViewingEnvironment: try AmbientViewingEnvironmentV4(
                ambientIlluminance: 123_456,
                ambientLight: try HDRChromaticityV4(
                    x: 15_635,
                    y: 16_450,
                    label: "ambient"
                )
            )
        )
    }

    private static func installNestedAttachment(on buffer: CVPixelBuffer) {
        let nested: NSDictionary = [
            "array": [true, NSNumber(value: 7)],
            "blob": Data("ash".utf8),
            "date": Date(timeIntervalSince1970: 1_700_000_000)
        ]
        CVBufferSetAttachment(
            buffer,
            "MirmirParityNested" as CFString,
            nested,
            .shouldPropagate
        )
    }

    private static func checkpointFormatIdentity(
        runtime: ASHVerifiedRuntimeBundleV4,
        configuration: DeterministicPreparedConfigurationV4
    ) -> ASHSHA256V4 {
        ASHSHA256V4(rawData: Data(
            [
                ASHRuntimeManifestV4.runtimeIdentity,
                runtime.manifestSHA256.rawValue,
                configuration.storage.rawValue,
                String(configuration.sourceWidth),
                String(configuration.sourceHeight),
                String(configuration.targetWidth),
                String(configuration.targetHeight),
                configuration.scaleRouteIdentity
            ].joined(separator: "|").utf8
        ))
    }

    private static func alphaSamples(
        width: Int,
        height: Int,
        maximum: UInt16,
        association: AlphaAssociationV4
    ) -> [AlphaSampleV4] {
        let scale = Int(maximum)
        var samples: [AlphaSampleV4] = []
        samples.reserveCapacity(width * height)
        for index in 0..<(width * height) {
            let x = index % width
            let y = index / width
            let alpha = (x + y).isMultiple(of: 4)
                ? 0
                : UInt16((x * 17_003 + y * 11_111 + scale / 3) % (scale + 1))
            let straight = AlphaSampleV4(
                red: UInt16((x * 9_973 + y * 2_003 + 101) % (scale + 1)),
                green: UInt16((x * 4_099 + y * 7_919 + 211) % (scale + 1)),
                blue: UInt16((x * 2_057 + y * 13_007 + 307) % (scale + 1)),
                alpha: alpha
            )
            guard association == .premultiplied, alpha > 0 else {
                samples.append(alpha == 0
                    ? AlphaSampleV4(red: 0, green: 0, blue: 0, alpha: 0)
                    : straight)
                continue
            }
            func premultiply(_ value: UInt16) -> UInt16 {
                UInt16((UInt64(value) * UInt64(alpha) + UInt64(maximum / 2))
                    / UInt64(maximum))
            }
            samples.append(AlphaSampleV4(
                red: premultiply(straight.red),
                green: premultiply(straight.green),
                blue: premultiply(straight.blue),
                alpha: alpha
            ))
        }
        return samples
    }

    private static func makePackedBuffer(
        layout: Alpha4444PackedLayoutV4,
        width: Int,
        height: Int,
        padding: Int,
        sentinel: UInt8
    ) throws -> CVPixelBuffer {
        let rowBytes = width * layout.bytesPerPixel + padding
        let byteCount = rowBytes * height
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: 64
        )
        storage.initializeMemory(as: UInt8.self, repeating: sentinel, count: byteCount)
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            width,
            height,
            layout.pixelFormat,
            storage,
            rowBytes,
            { _, base in base?.deallocate() },
            nil,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            storage.deallocate()
            throw ParityCaptureError.invalidFixture("packed buffer creation failed")
        }
        return buffer
    }

    private static func installAlphaAssociation(
        _ association: AlphaAssociationV4,
        on buffer: CVPixelBuffer
    ) {
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferAlphaChannelModeKey,
            association == .straight
                ? kCVImageBufferAlphaChannelMode_StraightAlpha
                : kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
            .shouldPropagate
        )
    }

    private static func visiblePixelSequence(
        _ buffers: [CVPixelBuffer],
        storage: PixelStorageV4
    ) throws -> Data {
        var result = Data()
        appendUInt32(UInt32(buffers.count), to: &result)
        for buffer in buffers {
            result.append(try visiblePixelFrame(buffer, storage: storage))
        }
        return result
    }

    private static func visiblePixelFrame(
        _ buffer: CVPixelBuffer,
        storage: PixelStorageV4
    ) throws -> Data {
        let layout = PixelLayoutV4(storage: storage)
        try layout.validateStructure(of: buffer)
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw ParityCaptureError.invalidFixture("pixel buffer lock failed")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var result = Data()
        appendUInt32(UInt32(CVPixelBufferGetWidth(buffer)), to: &result)
        appendUInt32(UInt32(CVPixelBufferGetHeight(buffer)), to: &result)
        appendUInt32(UInt32(layout.planes.count), to: &result)
        for (planeIndex, plane) in layout.planes.enumerated() {
            let width = CVPixelBufferGetWidthOfPlane(buffer, planeIndex)
            let height = CVPixelBufferGetHeightOfPlane(buffer, planeIndex)
            let elementBytes = plane.componentsPerElement * plane.bytesPerComponent
            let bytes = try activePlaneBytes(
                base: CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex),
                rowStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex),
                activeRowBytes: width * elementBytes,
                height: height
            )
            appendUInt32(UInt32(width), to: &result)
            appendUInt32(UInt32(height), to: &result)
            appendUInt32(UInt32(elementBytes), to: &result)
            appendUInt32(UInt32(bytes.count), to: &result)
            result.append(bytes)
        }
        return result
    }

    private static func visiblePackedSequence(
        _ buffers: [CVPixelBuffer],
        layout: Alpha4444PackedLayoutV4
    ) throws -> Data {
        var result = Data()
        appendUInt32(UInt32(buffers.count), to: &result)
        for buffer in buffers {
            let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
            guard status == kCVReturnSuccess else {
                throw ParityCaptureError.invalidFixture("packed buffer lock failed")
            }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let bytes = try activePlaneBytes(
                base: CVPixelBufferGetBaseAddress(buffer),
                rowStride: CVPixelBufferGetBytesPerRow(buffer),
                activeRowBytes: width * layout.bytesPerPixel,
                height: height
            )
            appendUInt32(UInt32(width), to: &result)
            appendUInt32(UInt32(height), to: &result)
            appendUInt32(1, to: &result)
            appendUInt32(UInt32(width), to: &result)
            appendUInt32(UInt32(height), to: &result)
            appendUInt32(UInt32(layout.bytesPerPixel), to: &result)
            appendUInt32(UInt32(bytes.count), to: &result)
            result.append(bytes)
        }
        return result
    }

    private static func activePlaneBytes(
        base: UnsafeMutableRawPointer?,
        rowStride: Int,
        activeRowBytes: Int,
        height: Int
    ) throws -> Data {
        guard let base, rowStride >= activeRowBytes else {
            throw ParityCaptureError.invalidFixture("invalid visible plane")
        }
        var result = Data(capacity: activeRowBytes * height)
        for y in 0..<height {
            result.append(
                base.advanced(by: y * rowStride)
                    .assumingMemoryBound(to: UInt8.self),
                count: activeRowBytes
            )
        }
        return result
    }

    private static func frameAttachments(
        _ buffer: CVPixelBuffer
    ) throws -> [ParityAttachmentValue] {
        var result: [ParityAttachmentValue] = []
        for (mode, name) in [
            (CVAttachmentMode.shouldPropagate, "should_propagate"),
            (.shouldNotPropagate, "should_not_propagate")
        ] {
            guard let raw = CVBufferCopyAttachments(buffer, mode) else { continue }
            let dictionary = raw as NSDictionary
            for (key, value) in dictionary {
                guard let key = key as? String else {
                    throw ParityCaptureError.invalidFixture(
                        "attachment dictionary contains a non-string key"
                    )
                }
                result.append(ParityAttachmentValue(
                    key: key,
                    mode: name,
                    value: try canonicalAttachmentValue(value)
                ))
            }
        }
        let sorted = result.sorted { $0.key < $1.key }
        guard Set(sorted.map(\.key)).count == sorted.count else {
            throw ParityCaptureError.invalidFixture("duplicate attachment key")
        }
        return sorted
    }

    private static func canonicalAttachmentValue(
        _ value: Any
    ) throws -> ParityAttachmentPayload {
        if value is NSNull { return .null }
        let object = value as AnyObject
        let typeID = CFGetTypeID(object)
        if typeID == CFBooleanGetTypeID() {
            return .boolean((value as! NSNumber).boolValue)
        }
        if typeID == CFStringGetTypeID() {
            return .string(value as! String)
        }
        if typeID == CFDataGetTypeID() {
            return .data((value as! Data).base64EncodedString())
        }
        if typeID == CFDateGetTypeID() {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds
            ]
            return .date(formatter.string(from: value as! Date))
        }
        if typeID == CFNumberGetTypeID() {
            let number = value as! NSNumber
            switch CFNumberGetType(number) {
            case .float32Type, .float64Type, .floatType, .doubleType,
                 .cgFloatType:
                return .realBits(String(
                    format: "%016llx",
                    number.doubleValue.bitPattern
                ))
            default:
                let unsignedTokens = "CISLQ"
                let token = String(cString: number.objCType)
                if unsignedTokens.contains(token) {
                    return .unsignedInteger(String(number.uint64Value))
                }
                return .signedInteger(String(number.int64Value))
            }
        }
        if let array = value as? [Any] {
            return .array(try array.map(canonicalAttachmentValue))
        }
        if let dictionary = value as? NSDictionary {
            var entries: [ParityAttachmentDictionaryEntry] = []
            for (key, nested) in dictionary {
                guard let key = key as? String else {
                    throw ParityCaptureError.invalidFixture(
                        "nested attachment dictionary has a non-string key"
                    )
                }
                entries.append(ParityAttachmentDictionaryEntry(
                    key: key,
                    value: try canonicalAttachmentValue(nested)
                ))
            }
            return .dictionary(entries.sorted { $0.key < $1.key })
        }
        throw ParityCaptureError.invalidFixture(
            "unsupported attachment value \(type(of: value))"
        )
    }

    private static func fillAllStorageBytes(
        _ buffer: CVPixelBuffer,
        sentinel: UInt8
    ) throws {
        let status = CVPixelBufferLockBaseAddress(buffer, [])
        guard status == kCVReturnSuccess else {
            throw ParityCaptureError.invalidFixture("pixel buffer lock failed")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
                throw ParityCaptureError.invalidFixture("missing plane")
            }
            memset(
                base,
                Int32(sentinel),
                CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                    * CVPixelBufferGetHeightOfPlane(buffer, plane)
            )
        }
    }

    private static func paddingByteCount(
        _ buffer: CVPixelBuffer,
        storage: PixelStorageV4
    ) throws -> Int {
        let layout = PixelLayoutV4(storage: storage)
        return try layout.planes.indices.reduce(0) { total, planeIndex in
            let plane = layout.planes[planeIndex]
            let active = CVPixelBufferGetWidthOfPlane(buffer, planeIndex)
                * plane.componentsPerElement * plane.bytesPerComponent
            let padding = CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
                - active
            guard padding >= 0 else {
                throw ParityCaptureError.invalidFixture("invalid plane stride")
            }
            return total + padding
                * CVPixelBufferGetHeightOfPlane(buffer, planeIndex)
        }
    }

    private static func paddingBytes(
        _ buffer: CVPixelBuffer,
        storage: PixelStorageV4
    ) throws -> [UInt8] {
        let layout = PixelLayoutV4(storage: storage)
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw ParityCaptureError.invalidFixture("pixel buffer lock failed")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var result: [UInt8] = []
        for planeIndex in layout.planes.indices {
            let plane = layout.planes[planeIndex]
            let active = CVPixelBufferGetWidthOfPlane(buffer, planeIndex)
                * plane.componentsPerElement * plane.bytesPerComponent
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex),
                  stride >= active else {
                throw ParityCaptureError.invalidFixture("invalid plane")
            }
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, planeIndex) {
                let row = base.advanced(by: y * stride)
                    .assumingMemoryBound(to: UInt8.self)
                result.append(contentsOf: UnsafeBufferPointer(
                    start: row.advanced(by: active),
                    count: stride - active
                ))
            }
        }
        return result
    }

    private static func packedPaddingBytes(
        _ buffer: CVPixelBuffer,
        layout: Alpha4444PackedLayoutV4
    ) throws -> [UInt8] {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw ParityCaptureError.invalidFixture("packed buffer lock failed")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let active = CVPixelBufferGetWidth(buffer) * layout.bytesPerPixel
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var result: [UInt8] = []
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            let row = base.advanced(by: y * stride)
                .assumingMemoryBound(to: UInt8.self)
            result.append(contentsOf: UnsafeBufferPointer(
                start: row.advanced(by: active),
                count: stride - active
            ))
        }
        return result
    }

    private static func makeArtifactManifest(
        root: URL,
        excluding: Set<String>
    ) throws -> ParityArtifactManifest {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ParityCaptureError.invalidOutput("cannot enumerate artifacts")
        }
        var artifacts: [ParityArtifact] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            if values.isSymbolicLink == true {
                throw ParityCaptureError.invalidOutput("symbolic link in capture")
            }
            guard values.isRegularFile == true else { continue }
            let relative = relativePath(url, to: root)
            if excluding.contains(relative) { continue }
            artifacts.append(try artifact(url, relativeTo: root))
        }
        return ParityArtifactManifest(
            schemaVersion: "mirmir-ash-v4-cpu-metal-parity-artifacts-v2",
            artifacts: artifacts.sorted { $0.path < $1.path }
        )
    }

    private static func artifact(
        _ url: URL,
        relativeTo root: URL
    ) throws -> ParityArtifact {
        let data = try Data(contentsOf: url)
        return ParityArtifact(
            path: relativePath(url, to: root),
            byteCount: data.count,
            sha256: sha256(data)
        )
    }

    private static func relativePath(_ url: URL, to root: URL) -> String {
        String(url.standardizedFileURL.path
            .dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.allSatisfy { $0.isHexDigit }
    }

    private static func requiredEnvironment(
        _ key: String,
        in environment: [String: String]
    ) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw ParityCaptureError.invalidEnvironment("missing \(key)")
        }
        return value
    }

    private static func createNewDirectory(_ url: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            let contents = try manager.contentsOfDirectory(atPath: url.path)
            guard isDirectory.boolValue, contents.isEmpty else {
                throw ParityCaptureError.invalidOutput(
                    "refusing to overwrite nonempty \(url.path)"
                )
            }
        } else {
            try manager.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

}

@available(macOS 15.4, *)
private enum MirmirPackagedQualityCaptureV4 {
    private struct CorpusManifest: Decodable {
        let schemaVersion: String
        let contractSHA256: String
        let cases: [CorpusCase]
    }

    private struct CorpusCase: Decodable {
        let id: String
        let clipID: String
        let cohort: String
        let frameIndex: Int
        let pixelFormat: String
        let sourceWidth: Int
        let sourceHeight: Int
        let targetWidth: Int
        let targetHeight: Int
        let sourceFile: String
        let sourceByteCount: Int
        let sourceSHA256: String
        let referenceFile: String
        let referenceByteCount: Int
        let referenceSHA256: String
    }

    private struct CaptureCase: Codable {
        let id: String
        let outputs: [String: String]
        let milliseconds: [String: Double]
    }

    private struct CaptureManifest: Codable {
        let schemaVersion: String
        let contractSHA256: String
        let corpusManifestSHA256: String
        let sourceCommit: String
        let sourceTreeIdentitySHA256: String
        let candidateBackendID: String
        let candidateImplementationVersion: String
        let runtimeManifestSHA256: String
        let runtimeSourceRevision: String
        let productionRuntimeLocked: Bool
        let fullMirrorIdentityPass: Bool
        let warmupCount: Int
        let evidenceRequestSHA256: String
        let observerSourceSHA256: String
        let packagedCandidateIdentity: MirmirPackagedCandidateIdentityV4
        let cases: [CaptureCase]
    }

    private enum Variant: String, CaseIterable {
        case candidateV4 = "candidate_v4"
        case uniformPriors = "uniform_priors"
        case randomizedStateMessage = "randomized_state_message"
        case temporalHysteresisOff = "temporal_hysteresis_off"
        case motionHistoryOff = "motion_history_off"
    }

    private enum AblationMode {
        case full
        case uniformPriors
        case randomizedStateMessage(seed: UInt64)
        case temporalHysteresisOff
        case motionHistoryOff
    }

    private final class AblationPipeline {
        private let mode: AblationMode
        private let storage: PixelStorageV4
        private let scaler: FixedPointPixelBufferScalerV4
        private let measurementContract: ASHMeasurementContractV4
        private let program: ASHDepthFourBranchProgramV4
        private let formatIdentity: ASHSHA256V4
        private var history: ASHTemporalHistoryV4
        private var previousMeasurementFrame: PixelBufferSignalFrameV4?
        private var previousMeasurementState: ASHState?

        init(
            mode: AblationMode,
            storage: PixelStorageV4,
            sourceWidth: Int,
            sourceHeight: Int,
            targetWidth: Int,
            targetHeight: Int,
            runtime: ASHVerifiedRuntimeBundleV4
        ) throws {
            self.mode = mode
            self.storage = storage
            self.scaler = try FixedPointPixelBufferScalerV4(
                backend: .cpu,
                storage: storage,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                borderRule: .reflect101
            )
            self.measurementContract = try runtime.measurementContract()
            self.program = try runtime.branchProgram()
            self.formatIdentity = ASHSHA256V4(
                rawData: Data(
                    "ash-v4-quality-ablation|\(storage.rawValue)|"
                        .appending("\(sourceWidth)x\(sourceHeight)|")
                        .appending("\(targetWidth)x\(targetHeight)").utf8
                )
            )
            self.history = try ASHTemporalHistoryV4(capacity: 3)
        }

        func process(
            source: CVPixelBuffer,
            destination: CVPixelBuffer,
            frameIndex: Int
        ) async throws {
            let sourceSignal = try PixelBufferSignalCodecV4.read(
                source,
                storage: storage
            )
            let exactPTS = try ExactRationalV4(Int64(frameIndex), 30)
            let sourcePlane = try temporalLumaPlane(from: sourceSignal)
            let neutralState = try ASHState(rawValue: 0)
            let sourceTemporalFrame = try ASHTemporalFrameV4(
                frameID: "quality-measurement-\(frameIndex)",
                streamID: "quality-measurement-stream",
                formatIdentity: formatIdentity,
                ordinal: Int64(frameIndex),
                presentationTime: exactPTS,
                luma: sourcePlane,
                tileStateRawValues: [
                    previousMeasurementState?.rawValue
                        ?? neutralState.rawValue
                ],
                cadenceID: "progressive"
            )
            var measurementMotion: ASHTemporalMotionAnalysisV4?
            if case .temporalHysteresisOff = mode {
                measurementMotion = nil
            } else if frameIndex > 0,
                      let previousMeasurementFrame {
                let previousSourceFrame = try ASHTemporalFrameV4(
                    frameID: "quality-measurement-\(frameIndex - 1)",
                    streamID: sourceTemporalFrame.streamID,
                    formatIdentity: sourceTemporalFrame.formatIdentity,
                    ordinal: Int64(frameIndex - 1),
                    presentationTime: try ExactRationalV4(
                        Int64(frameIndex - 1),
                        30
                    ),
                    luma: try temporalLumaPlane(
                        from: previousMeasurementFrame
                    ),
                    tileStateRawValues: [
                        previousMeasurementState?.rawValue
                            ?? neutralState.rawValue
                    ],
                    cadenceID: "progressive"
                )
                measurementMotion = try ASHTemporalMotionAnalyzerV4.analyze(
                    current: sourceTemporalFrame,
                    previous: previousSourceFrame
                )
            }
            let measurementReset: ASHMeasurementResetTriggerV4?
            if case .temporalHysteresisOff = mode {
                measurementReset = .streamStart
            } else if previousMeasurementFrame == nil {
                measurementReset = .streamStart
            } else if measurementMotion?.sceneCut == true {
                measurementReset = .sceneCut
            } else {
                measurementReset = nil
            }
            let measurementHistory: ASHMeasurementHistoryV4
            if let measurementReset {
                measurementHistory = .reset(measurementReset)
            } else if let previousMeasurementState {
                measurementHistory = .continuous(
                    previousState: previousMeasurementState
                )
            } else {
                measurementHistory = .reset(.streamStart)
            }
            let measurement = try ASHMeasurementExtractorV4.extract(
                frame: sourceSignal,
                previousFrame: {
                    if case .temporalHysteresisOff = mode { return nil }
                    return previousMeasurementFrame
                }(),
                contract: measurementContract,
                history: measurementHistory,
                motionCompensatedTemporalEvidenceQ16:
                    measurementMotion?.temporalEvidenceQ16
                        ?? (measurementReset != nil ? 0 : nil)
            )
            try await scaler.process(source: source, destination: destination)
            let outputSignal = try PixelBufferSignalCodecV4.read(
                destination,
                storage: storage
            )
            let lumaPlane = outputSignal.planes[0]
            let bounds = lumaPlane.componentBounds[0]
            let spatial = try ASHTemporalPlaneV4(
                width: lumaPlane.width,
                height: lumaPlane.height,
                minimumCode: bounds.minimum,
                maximumCode: bounds.maximum,
                samples: try lumaPlane.component(0)
            )
            let state = try selectedState(
                measured: measurement.projection.state,
                frameIndex: frameIndex
            )
            let conditionedSpatial: ASHTemporalPlaneV4
            if case .uniformPriors = mode {
                conditionedSpatial = try uniformSpatialReconstruction(
                    spatial: spatial
                )
            } else {
                conditionedSpatial = try ASHSpatialReconstructorV4.reconstruct(
                    spatial: spatial,
                    sourceState: state,
                    program: program
                ).output
            }
            let frame = try ASHTemporalFrameV4(
                frameID: "quality-frame-\(frameIndex)",
                streamID: "quality-stream",
                formatIdentity: formatIdentity,
                ordinal: Int64(frameIndex),
                presentationTime: exactPTS,
                luma: conditionedSpatial,
                tileStateRawValues: [state.rawValue],
                cadenceID: "progressive"
            )

            var resetReason: ASHTemporalResetReasonV4?
                = history.frames.isEmpty ? .streamStart : nil
            if measurementMotion?.sceneCut == true {
                resetReason = .sceneCut
            }
            var motionAnalysis: ASHTemporalMotionAnalysisV4?
            if case .motionHistoryOff = mode {
                motionAnalysis = nil
            } else if let previous = history.frames.last {
                let motion = try ASHTemporalMotionAnalyzerV4.analyze(
                    current: frame,
                    previous: previous
                )
                if motion.sceneCut {
                    resetReason = .sceneCut
                } else {
                    motionAnalysis = motion
                }
            }

            let reconstructed: ASHTemporalPlaneV4
            if case .uniformPriors = mode {
                reconstructed = try uniformReconstruction(
                    spatial: conditionedSpatial,
                    motionAnalysis: motionAnalysis,
                    resetReason: resetReason
                )
            } else {
                reconstructed = try ASHTemporalReconstructorV4.reconstruct(
                    spatial: conditionedSpatial,
                    motionAnalysis: motionAnalysis,
                    sourceState: state,
                    resetReason: resetReason,
                    program: program
                ).output
            }
            var outputPlanes = outputSignal.planes
            outputPlanes[0] = try lumaPlane.replacingComponent(
                0,
                with: reconstructed.samples
            )
            try PixelBufferSignalCodecV4.write(
                PixelBufferSignalFrameV4(
                    storage: outputSignal.storage,
                    width: outputSignal.width,
                    height: outputSignal.height,
                    planes: outputPlanes
                ),
                to: destination
            )
            if let resetReason {
                try history.reset(reason: resetReason)
            }
            try history.append(ASHTemporalFrameV4(
                frameID: frame.frameID,
                streamID: frame.streamID,
                formatIdentity: frame.formatIdentity,
                ordinal: frame.ordinal,
                presentationTime: frame.presentationTime,
                luma: reconstructed,
                tileStateRawValues: frame.tileStateRawValues,
                cadenceID: frame.cadenceID
            ))
            previousMeasurementFrame = sourceSignal
            previousMeasurementState = measurement.projection.state
        }

        private func temporalLumaPlane(
            from frame: PixelBufferSignalFrameV4
        ) throws -> ASHTemporalPlaneV4 {
            guard let luma = frame.planes.first,
                  luma.componentsPerElement == 1,
                  let bounds = luma.componentBounds.first else {
                throw ASHTemporalV4Error.invalidConfiguration
            }
            return try ASHTemporalPlaneV4(
                width: luma.width,
                height: luma.height,
                minimumCode: bounds.minimum,
                maximumCode: bounds.maximum,
                samples: try luma.component(0)
            )
        }

        private func selectedState(
            measured: ASHState,
            frameIndex: Int
        ) throws -> ASHState {
            guard case .randomizedStateMessage(let seed) = mode else {
                return measured
            }
            var value = seed &+ UInt64(frameIndex) &* 0x9e3779b97f4a7c15
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            value ^= value >> 31
            let payload = (0..<ASHState.payloadBitCount).map { index in
                Int((value >> UInt64(index)) & 1)
            }
            return try ASHState(payloadBits: payload)
        }

        private func uniformReconstruction(
            spatial: ASHTemporalPlaneV4,
            motionAnalysis: ASHTemporalMotionAnalysisV4?,
            resetReason: ASHTemporalResetReasonV4?
        ) throws -> ASHTemporalPlaneV4 {
            guard resetReason == nil,
                  let motionAnalysis else {
                return spatial
            }
            try motionAnalysis.validate()
            guard !motionAnalysis.sceneCut,
                  let aligned = motionAnalysis.alignedPrevious else {
                return spatial
            }
            guard spatial.width == aligned.width,
                  spatial.height == aligned.height,
                  spatial.minimumCode == aligned.minimumCode,
                  spatial.maximumCode == aligned.maximumCode else {
                throw ASHTemporalV4Error.planeGeometryMismatch
            }
            guard let basisIndex = program.operatorManifest.basisIDs
                .firstIndex(of: "regularization") else {
                throw ASHTemporalV4Error.invalidConfiguration
            }
            var numerator: UInt64 = 0
            for weight in program.baseWeightsByMessage {
                let entry = try program.operatorManifest.entry(
                    forMessage: weight.messageRawValue
                )
                let coefficient = entry.coefficients[basisIndex]
                if coefficient > 0 {
                    numerator += weight.massNumerator * UInt64(coefficient)
                }
            }
            let stateWeightQ16 = try roundedFraction(
                numerator: numerator * UInt64(ASHNormalizedQ16V4.scale),
                denominator: program.baseMassDenominator
            )
            let scale = UInt64(ASHNormalizedQ16V4.scale)
            let stateBoostQ16 = try roundedShift(
                stateWeightQ16,
                bits: 1
            )
            let confidenceGainQ16 = scale + stateBoostQ16
            var samples = spatial.samples
            for vector in motionAnalysis.vectors where !vector.occluded {
                let historyWeight = min(
                    UInt64(
                        ASHTemporalReconstructorV4.maximumHistoryWeightQ16
                    ),
                    try roundedShift(
                        UInt64(vector.confidenceQ16) * confidenceGainQ16,
                        bits: 16
                    )
                )
                guard historyWeight > 0 else { continue }
                let currentWeight = scale - historyWeight
                for y in vector.originY..<(vector.originY + vector.height) {
                    let row = y * spatial.width
                    for x in vector.originX..<(vector.originX + vector.width) {
                        let index = row + x
                        let value = UInt64(spatial.samples[index])
                            * currentWeight
                            + UInt64(aligned.samples[index]) * historyWeight
                        samples[index] = UInt16(
                            try roundedShift(value, bits: 16)
                        )
                    }
                }
            }
            return try spatial.replacing(samples: samples)
        }

        private func uniformSpatialReconstruction(
            spatial: ASHTemporalPlaneV4
        ) throws -> ASHTemporalPlaneV4 {
            guard program.operatorManifest.basisIDs == [
                "horizontal_detail",
                "vertical_detail",
                "isotropic_detail",
                "regularization"
            ] else {
                throw ASHTemporalV4Error.invalidConfiguration
            }
            var numerators = Array(repeating: UInt64(0), count: 4)
            for weight in program.baseWeightsByMessage {
                let entry = try program.operatorManifest.entry(
                    forMessage: weight.messageRawValue
                )
                guard entry.coefficients.count == numerators.count else {
                    throw ASHTemporalV4Error.invalidConfiguration
                }
                for index in numerators.indices {
                    let coefficient = entry.coefficients[index]
                    guard coefficient >= 0 else {
                        throw ASHTemporalV4Error.invalidConfiguration
                    }
                    numerators[index] += weight.massNumerator
                        * UInt64(coefficient)
                }
            }
            var gains = try numerators.map { numerator in
                let expectationQ16 = try roundedFraction(
                    numerator: numerator
                        * UInt64(ASHNormalizedQ16V4.scale),
                    denominator: program.baseMassDenominator
                )
                return try roundedFraction(
                    numerator: expectationQ16
                        * UInt64(
                            ASHSpatialReconstructorV4.maximumDetailGainQ16
                        ),
                    denominator: UInt64(ASHNormalizedQ16V4.scale)
                )
            }
            gains[3] = 0
            let source = spatial.samples
            var output = source
            for y in 0..<spatial.height {
                let upY = max(0, y - 1)
                let downY = min(spatial.height - 1, y + 1)
                for x in 0..<spatial.width {
                    let leftX = max(0, x - 1)
                    let rightX = min(spatial.width - 1, x + 1)
                    let index = y * spatial.width + x
                    let center = Int64(source[index])
                    let left = Int64(source[y * spatial.width + leftX])
                    let right = Int64(source[y * spatial.width + rightX])
                    let up = Int64(source[upY * spatial.width + x])
                    let down = Int64(source[downY * spatial.width + x])
                    let horizontalAverage = try roundedSignedFraction(
                        numerator: left + right,
                        denominator: 2
                    )
                    let verticalAverage = try roundedSignedFraction(
                        numerator: up + down,
                        denominator: 2
                    )
                    let isotropicAverage = try roundedSignedFraction(
                        numerator: left + right + up + down,
                        denominator: 4
                    )
                    let weighted = (center - horizontalAverage)
                            * Int64(gains[0])
                        + (center - verticalAverage) * Int64(gains[1])
                        + (center - isotropicAverage) * Int64(gains[2])
                    let adjustment = try roundedSignedFraction(
                        numerator: weighted,
                        denominator: Int64(ASHNormalizedQ16V4.scale)
                    )
                    output[index] = UInt16(min(
                        Int64(spatial.maximumCode),
                        max(Int64(spatial.minimumCode), center + adjustment)
                    ))
                }
            }
            return try spatial.replacing(samples: output)
        }

        private func roundedFraction(
            numerator: UInt64,
            denominator: UInt64
        ) throws -> UInt64 {
            guard denominator > 0 else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            var quotient = numerator / denominator
            let remainder = numerator % denominator
            let complement = denominator - remainder
            if remainder > complement
                || (remainder == complement && quotient & 1 == 1) {
                quotient += 1
            }
            return quotient
        }

        private func roundedShift(_ value: UInt64, bits: Int) throws -> UInt64 {
            guard (1...63).contains(bits) else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            let denominator = UInt64(1) << bits
            return try roundedFraction(
                numerator: value,
                denominator: denominator
            )
        }

        private func roundedSignedFraction(
            numerator: Int64,
            denominator: Int64
        ) throws -> Int64 {
            guard denominator > 0 else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            let magnitude = try roundedFraction(
                numerator: numerator.magnitude,
                denominator: UInt64(denominator)
            )
            guard magnitude <= UInt64(Int64.max) else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            return numerator < 0 ? -Int64(magnitude) : Int64(magnitude)
        }
    }

    static func capture(
        environment: [String: String],
        packageIdentity: MirmirPackagedCandidateIdentityV4,
        requestSHA256: String,
        observerSourceSHA256: String
    ) async throws -> URL {
        guard let outputValue = environment[
            "MIRMIR_V4_QUALITY_CAPTURE_DIR"
        ],
              let corpusValue = environment[
                "MIRMIR_V4_QUALITY_CORPUS_MANIFEST"
              ],
              !outputValue.isEmpty,
              !corpusValue.isEmpty else {
            throw MirmirPackagedEvidenceErrorV4.capture(
                "quality capture paths are absent"
            )
        }
        let output = URL(fileURLWithPath: outputValue, isDirectory: true)
        let corpusURL = URL(fileURLWithPath: corpusValue)
        let corpusRoot = corpusURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: output.appendingPathComponent("artifacts", isDirectory: true),
            withIntermediateDirectories: true
        )
        let corpusData = try Data(contentsOf: corpusURL)
        let corpus = try JSONDecoder().decode(CorpusManifest.self, from: corpusData)
        guard corpus.schemaVersion
                == "mirmir-ash-v4-quality-corpus-v1",
              let expectedContract = environment[
                "MIRMIR_V4_QUALITY_CONTRACT_SHA256"
              ],
              corpus.contractSHA256 == expectedContract else {
            throw MirmirPackagedEvidenceErrorV4.capture(
                "quality corpus or contract identity differs"
            )
        }
        guard ASHProductionP06TrustRootV4.isConfigured else {
            throw MirmirPackagedEvidenceErrorV4.capture(
                "production P06 trust root is not configured"
            )
        }
        let runtime = try ASHP06RuntimeProviderV4.production().load()
        try runtime.verifyBinding()
        let productionRuntimeLocked =
            runtime.manifest.releaseStatus == .releaseQualified
            && runtime.manifestSHA256
                == ASHProductionP06TrustRootV4.manifestSHA256
            && runtime.manifest.provenance.sourceRevision
                == ASHProductionP06TrustRootV4.sourceRevision
            && runtime.manifest.provenance.builderSourceSHA256
                == ASHProductionP06TrustRootV4.builderSourceSHA256

        let clips = Dictionary(grouping: corpus.cases, by: \.clipID)
        guard let firstCase = corpus.cases.sorted(by: {
            $0.id < $1.id
        }).first else {
            throw MirmirPackagedEvidenceErrorV4.capture(
                "quality corpus has no cases"
            )
        }
        try await runWarmups(
            first: firstCase,
            corpusRoot: corpusRoot,
            runtime: runtime,
            count: 5
        )
        var captures: [CaptureCase] = []
        var fullMirrorIdentityPass = true
        for clipID in clips.keys.sorted() {
            let cases = clips[clipID]!.sorted { $0.frameIndex < $1.frameIndex }
            guard let first = cases.first else { continue }
            guard cases.map(\.frameIndex) == Array(0..<cases.count) else {
                throw MirmirPackagedEvidenceErrorV4.capture(
                    "quality clip frame ordinals are not contiguous: \(clipID)"
                )
            }
            let storage = try storage(first.pixelFormat)
            let configuration = DeterministicPreparedConfigurationV4(
                backendID: .mirmirDeterministicCPU,
                executionBackend: .cpu,
                storage: storage,
                sourceWidth: first.sourceWidth,
                sourceHeight: first.sourceHeight,
                targetWidth: first.targetWidth,
                targetHeight: first.targetHeight,
                scanMode: .progressive
            )
            let candidate = try PreparedDeterministicV4Upscaler(
                configuration: configuration,
                runtime: runtime
            )
            let pipelines: [Variant: AblationPipeline] = [
                .candidateV4: try AblationPipeline(
                    mode: .full,
                    storage: storage,
                    sourceWidth: first.sourceWidth,
                    sourceHeight: first.sourceHeight,
                    targetWidth: first.targetWidth,
                    targetHeight: first.targetHeight,
                    runtime: runtime
                ),
                .uniformPriors: try AblationPipeline(
                    mode: .uniformPriors,
                    storage: storage,
                    sourceWidth: first.sourceWidth,
                    sourceHeight: first.sourceHeight,
                    targetWidth: first.targetWidth,
                    targetHeight: first.targetHeight,
                    runtime: runtime
                ),
                .randomizedStateMessage: try AblationPipeline(
                    mode: .randomizedStateMessage(seed: stableSeed(clipID)),
                    storage: storage,
                    sourceWidth: first.sourceWidth,
                    sourceHeight: first.sourceHeight,
                    targetWidth: first.targetWidth,
                    targetHeight: first.targetHeight,
                    runtime: runtime
                ),
                .temporalHysteresisOff: try AblationPipeline(
                    mode: .temporalHysteresisOff,
                    storage: storage,
                    sourceWidth: first.sourceWidth,
                    sourceHeight: first.sourceHeight,
                    targetWidth: first.targetWidth,
                    targetHeight: first.targetHeight,
                    runtime: runtime
                ),
                .motionHistoryOff: try AblationPipeline(
                    mode: .motionHistoryOff,
                    storage: storage,
                    sourceWidth: first.sourceWidth,
                    sourceHeight: first.sourceHeight,
                    targetWidth: first.targetWidth,
                    targetHeight: first.targetHeight,
                    runtime: runtime
                )
            ]

            for record in cases {
                let sourceURL = corpusRoot.appendingPathComponent(record.sourceFile)
                let bytes = try Data(contentsOf: sourceURL)
                guard bytes.count == record.sourceByteCount,
                      ASHSHA256V4(rawData: bytes).rawValue
                        == record.sourceSHA256 else {
                    throw MirmirPackagedEvidenceErrorV4.capture(
                        "quality source bytes differ: \(record.id)"
                    )
                }
                let source = try makeBuffer(
                    width: record.sourceWidth,
                    height: record.sourceHeight,
                    storage: storage,
                    bytes: bytes
                )
                var outputs: [String: String] = [:]
                var milliseconds: [String: Double] = [:]

                let candidateOutput = try makeBuffer(
                    width: record.targetWidth,
                    height: record.targetHeight,
                    storage: storage
                )
                let timing = FrameTiming(
                    frameIndex: record.frameIndex,
                    presentationTime: CMTime(value: Int64(record.frameIndex), timescale: 30),
                    duration: CMTime(value: 1, timescale: 30)
                )
                milliseconds[Variant.candidateV4.rawValue] = try await measured {
                    try await candidate.process(
                        source: FramePixelBuffer(source),
                        destination: FramePixelBuffer(candidateOutput),
                        timing: timing
                    )
                }
                outputs[Variant.candidateV4.rawValue] = try writeOutput(
                    candidateOutput,
                    record: record,
                    variant: .candidateV4,
                    output: output
                )

                for variant in [
                    Variant.uniformPriors,
                    .randomizedStateMessage,
                    .temporalHysteresisOff,
                    .motionHistoryOff
                ] {
                    let destination = try makeBuffer(
                        width: record.targetWidth,
                        height: record.targetHeight,
                        storage: storage
                    )
                    milliseconds[variant.rawValue] = try await measured {
                        try await pipelines[variant]!.process(
                            source: source,
                            destination: destination,
                            frameIndex: record.frameIndex
                        )
                    }
                    outputs[variant.rawValue] = try writeOutput(
                        destination,
                        record: record,
                        variant: variant,
                        output: output
                    )
                }

                let mirror = try makeBuffer(
                    width: record.targetWidth,
                    height: record.targetHeight,
                    storage: storage
                )
                let mirrorMilliseconds = try await measured {
                    try await pipelines[.candidateV4]!.process(
                        source: source,
                        destination: mirror,
                        frameIndex: record.frameIndex
                    )
                }
                _ = mirrorMilliseconds
                let mirrorBytes = try visibleBytes(mirror)
                let candidateBytes = try visibleBytes(candidateOutput)
                fullMirrorIdentityPass = fullMirrorIdentityPass
                    && mirrorBytes == candidateBytes
                captures.append(CaptureCase(
                    id: record.id,
                    outputs: outputs,
                    milliseconds: milliseconds
                ))
            }
            try await candidate.finish()
        }
        guard fullMirrorIdentityPass else {
            throw MirmirPackagedEvidenceErrorV4.capture(
                "candidate and full production mirror differ"
            )
        }
        let manifest = CaptureManifest(
            schemaVersion: "mirmir-ash-v4-quality-candidate-capture-v1",
            contractSHA256: expectedContract,
            corpusManifestSHA256: ASHSHA256V4(rawData: corpusData).rawValue,
            sourceCommit: environment[
                "MIRMIR_V4_QUALITY_SOURCE_COMMIT"
            ]!,
            sourceTreeIdentitySHA256: environment[
                "MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256"
            ]!,
            candidateBackendID: "mirmir_deterministic_cpu",
            candidateImplementationVersion: ASHRuntimeManifestV4.runtimeIdentity,
            runtimeManifestSHA256: runtime.manifestSHA256.rawValue,
            runtimeSourceRevision: runtime.manifest.provenance.sourceRevision,
            productionRuntimeLocked: productionRuntimeLocked,
            fullMirrorIdentityPass: fullMirrorIdentityPass,
            warmupCount: 5,
            evidenceRequestSHA256: requestSHA256,
            observerSourceSHA256: observerSourceSHA256,
            packagedCandidateIdentity: packageIdentity,
            cases: captures.sorted { $0.id < $1.id }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestURL = output.appendingPathComponent(
            "candidate-capture-manifest.json"
        )
        try encoder.encode(manifest).write(
            to: manifestURL,
            options: .atomic
        )
        return manifestURL
    }

    private static func runWarmups(
        first: CorpusCase,
        corpusRoot: URL,
        runtime: ASHVerifiedRuntimeBundleV4,
        count: Int
    ) async throws {
        let storage = try storage(first.pixelFormat)
        let source = try makeBuffer(
            width: first.sourceWidth,
            height: first.sourceHeight,
            storage: storage,
            bytes: Data(contentsOf: corpusRoot.appendingPathComponent(first.sourceFile))
        )
        let candidate = try PreparedDeterministicV4Upscaler(
            configuration: DeterministicPreparedConfigurationV4(
                backendID: .mirmirDeterministicCPU,
                executionBackend: .cpu,
                storage: storage,
                sourceWidth: first.sourceWidth,
                sourceHeight: first.sourceHeight,
                targetWidth: first.targetWidth,
                targetHeight: first.targetHeight,
                scanMode: .progressive
            ),
            runtime: runtime
        )
        for index in 0..<count {
            let candidateOutput = try makeBuffer(
                width: first.targetWidth,
                height: first.targetHeight,
                storage: storage
            )
            try await candidate.process(
                source: FramePixelBuffer(source),
                destination: FramePixelBuffer(candidateOutput),
                timing: FrameTiming(
                    frameIndex: index,
                    presentationTime: CMTime(value: Int64(index), timescale: 30),
                    duration: CMTime(value: 1, timescale: 30)
                )
            )
        }
        try await candidate.finish()
    }

    private static func storage(_ id: String) throws -> PixelStorageV4 {
        switch id {
        case "420v": .nv12VideoRange8Bit
        case "420f": .nv12FullRange8Bit
        default:
            throw MirmirPackagedEvidenceErrorV4.capture(
                "unsupported quality storage \(id)"
            )
        }
    }

    private static func makeBuffer(
        width: Int,
        height: Int,
        storage: PixelStorageV4,
        bytes: Data? = nil
    ) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            storage.pixelFormat,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String:
                    [:] as CFDictionary,
                kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ] as CFDictionary,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw MirmirPackagedEvidenceErrorV4.capture(
                "quality pixel-buffer allocation failed: \(status)"
            )
        }
        if let bytes {
            let expected = width * height * 3 / 2
            guard bytes.count == expected else {
                throw MirmirPackagedEvidenceErrorV4.capture(
                    "invalid quality NV12 bytes: \(width)x\(height)/\(bytes.count)"
                )
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            var offset = 0
            for plane in 0..<2 {
                let planeWidth = CVPixelBufferGetWidthOfPlane(buffer, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
                let components = plane == 0 ? 1 : 2
                let visibleRowBytes = planeWidth * components
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
                    .assumingMemoryBound(to: UInt8.self)
                bytes.withUnsafeBytes { raw in
                    let source = raw.bindMemory(to: UInt8.self)
                    for row in 0..<planeHeight {
                        base.advanced(by: row * stride).update(
                            from: source.baseAddress!.advanced(by: offset),
                            count: visibleRowBytes
                        )
                        offset += visibleRowBytes
                    }
                }
            }
        }
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferFieldCountKey,
            NSNumber(value: 1),
            .shouldPropagate
        )
        return buffer
    }

    private static func visibleBytes(
        _ buffer: CVPixelBuffer
    ) throws -> Data {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw MirmirPackagedEvidenceErrorV4.capture(
                "quality pixel buffer lock failed: \(status)"
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) == 2 else {
            throw MirmirPackagedEvidenceErrorV4.capture(
                "quality output is not bi-planar"
            )
        }
        var result = Data()
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(
                buffer,
                plane
            ) else {
                throw MirmirPackagedEvidenceErrorV4.capture(
                    "quality output plane \(plane) has no base address"
                )
            }
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let visible = width * (plane == 0 ? 1 : 2)
            guard visible > 0, height > 0, stride >= visible else {
                throw MirmirPackagedEvidenceErrorV4.capture(
                    "quality output plane \(plane) geometry is invalid"
                )
            }
            for row in 0..<height {
                result.append(
                    base.advanced(by: row * stride)
                        .assumingMemoryBound(to: UInt8.self),
                    count: visible
                )
            }
        }
        return result
    }

    private static func writeOutput(
        _ buffer: CVPixelBuffer,
        record: CorpusCase,
        variant: Variant,
        output: URL
    ) throws -> String {
        let relative = "artifacts/\(record.id)-\(variant.rawValue).nv12"
        try visibleBytes(buffer).write(
            to: output.appendingPathComponent(relative),
            options: .atomic
        )
        return relative
    }

    private static func stableSeed(_ text: String) -> UInt64 {
        text.utf8.reduce(UInt64(0xcbf29ce484222325)) {
            ($0 ^ UInt64($1)) &* 0x100000001b3
        }
    }

    private static func measured(
        _ operation: () async throws -> Void
    ) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000.0
    }
}

@available(macOS 15.4, *)
private enum MirmirPackagedPerformanceCaptureV4 {
    private struct BenchmarkCase: Codable, Sendable {
        let id: String
        let backendID: String
        let targetWidth: Int
        let targetHeight: Int

        var backend: UpscaleBackendID {
            switch backendID {
            case UpscaleBackendID.mirmirDeterministicCPU.rawValue:
                .mirmirDeterministicCPU
            case UpscaleBackendID.mirmirDeterministicMetal.rawValue:
                .mirmirDeterministicMetal
            default:
                preconditionFailure("unrecognized locked backend \(backendID)")
            }
        }
    }

    private struct InputIdentity: Codable {
        let sha256: String
        let byteCount: Int
        let width: Int
        let height: Int
        let codecFourCC: String
        let frameCount: Int
        let trackCount: Int
        let enabledVideoTrackCount: Int
        let durationNumerator: Int
        let durationTimescale: Int
        let allRequiredChecksPassed: Bool
    }

    private struct RequestIdentity: Codable {
        let codec: String
        let fileType: String
        let preserveAudio: Bool
        let overwriteExistingFile: Bool
    }

    private struct EngineRun: Codable {
        let sampleIndex: Int
        let frameMilliseconds: [Double]
        let processedFrameCount: Int
    }

    private struct Verification: Codable {
        let requestedBackendExecutedWithoutFallback: Bool
        let allInputTracksAccounted: Bool
        let exactEnabledVideoTrackCount: Bool
        let exactEncodedDimensions: Bool
        let exactCodec: Bool
        let exactFrameCount: Bool
        let exactPresentationTimestamps: Bool
        let exactDuration: Bool
        let bt709ColorContract: Bool
        let decodedVisiblePixelSHA256: String
        let semanticTrackManifestSHA256: String
        let allRequiredChecksPassed: Bool
    }

    private struct EndToEndRun: Codable {
        let sampleIndex: Int
        let wallMilliseconds: Double
        let peakResidentBytes: UInt64
        let processedFrameCount: Int
        let verification: Verification
    }

    private struct CaseCapture: Codable {
        let id: String
        let backendID: String
        let targetWidth: Int
        let targetHeight: Int
        let request: RequestIdentity
        let engineRuns: [EngineRun]
        let endToEndRuns: [EndToEndRun]
    }

    private struct Capture: Codable {
        let schemaVersion: String
        let variant: String
        let contractSHA256: String
        let captureSourceSHA256: String
        let sourceIdentitySHA256: String
        let sourceRevision: String
        let sourceTreeSHA256: String
        let buildConfiguration: String
        let warmupCount: Int
        let sampleCount: Int
        let input: InputIdentity
        let evidenceRequestSHA256: String
        let observerSourceSHA256: String
        let packagedCandidateIdentity: MirmirPackagedCandidateIdentityV4
        let cases: [CaseCapture]
    }

    private struct TrackManifest: Codable {
        let trackCount: Int
        let enabledVideoTrackCount: Int
        let codecFourCC: String
        let encodedWidth: Int
        let encodedHeight: Int
        let frameCount: Int
        let presentationTimes: [String]
        let duration: String
        let colorPrimaries: String
        let transferFunction: String
        let yCbCrMatrix: String
    }

    private struct AssetInspection {
        let trackCount: Int
        let enabledVideoTrackCount: Int
        let codecFourCC: String
        let width: Int
        let height: Int
        let frameCount: Int
        let presentationTimes: [CMTime]
        let duration: CMTime
        let colorPrimaries: String
        let transferFunction: String
        let yCbCrMatrix: String
        let decodedVisiblePixelSHA256: String
        let semanticTrackManifestSHA256: String
    }

    private struct DecodedInspection {
        let presentationTimes: [CMTime]
        let visiblePixelSHA256: String
    }

    private static let cases = [
        BenchmarkCase(
            id: "nv12-video-range-2x-cpu",
            backendID: UpscaleBackendID.mirmirDeterministicCPU.rawValue,
            targetWidth: 128,
            targetHeight: 96
        ),
        BenchmarkCase(
            id: "nv12-video-range-2x-metal",
            backendID: UpscaleBackendID.mirmirDeterministicMetal.rawValue,
            targetWidth: 128,
            targetHeight: 96
        ),
        BenchmarkCase(
            id: "nv12-video-range-3-over-2-cpu",
            backendID: UpscaleBackendID.mirmirDeterministicCPU.rawValue,
            targetWidth: 96,
            targetHeight: 72
        ),
        BenchmarkCase(
            id: "nv12-video-range-3-over-2-metal",
            backendID: UpscaleBackendID.mirmirDeterministicMetal.rawValue,
            targetWidth: 96,
            targetHeight: 72
        )
    ]

    static func capture(
        environment: [String: String],
        packageIdentity: MirmirPackagedCandidateIdentityV4,
        requestSHA256: String,
        observerSourceSHA256: String
    ) async throws -> URL {
        let captureDirectory = try requiredEnvironment(
            "MIRMIR_V4_PERFORMANCE_CAPTURE_DIR",
            in: environment
        )
        let inputURL = URL(fileURLWithPath: try requiredEnvironment(
            "MIRMIR_V4_PERFORMANCE_INPUT",
            in: environment
        ))
        let outputDirectory = URL(
            fileURLWithPath: captureDirectory,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let warmupCount = try positiveIntegerEnvironment(
            "MIRMIR_V4_PERFORMANCE_WARMUPS",
            minimum: 5,
            in: environment
        )
        let sampleCount = try positiveIntegerEnvironment(
            "MIRMIR_V4_PERFORMANCE_SAMPLES",
            minimum: 10,
            in: environment
        )
        let inputData = try Data(contentsOf: inputURL)
        let inputSHA256 = sha256(inputData)
        try requireEqual(
            inputSHA256,
            "1e2d65c2702dc3e47768293cf566ecd105282cb7d4ae58874dc313a77b53182d"
        )

        let source = try await VideoProbe().probe(url: inputURL)
        let inputInspection = try await inspectAsset(inputURL, decodePixels: false)
        let expectedDuration = CMTime(value: 1, timescale: 10)
        let inputChecks = inputInspection.trackCount == 1
            && inputInspection.enabledVideoTrackCount == 1
            && inputInspection.codecFourCC == "avc1"
            && inputInspection.width == 64
            && inputInspection.height == 48
            && inputInspection.frameCount == 3
            && CMTimeCompare(inputInspection.duration, expectedDuration) == 0
            && isBT709(inputInspection)
        try requireTrue(inputChecks, "the locked input semantic identity changed")
        let inputIdentity = InputIdentity(
            sha256: inputSHA256,
            byteCount: try inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1,
            width: inputInspection.width,
            height: inputInspection.height,
            codecFourCC: inputInspection.codecFourCC,
            frameCount: inputInspection.frameCount,
            trackCount: inputInspection.trackCount,
            enabledVideoTrackCount: inputInspection.enabledVideoTrackCount,
            durationNumerator: 1,
            durationTimescale: 10,
            allRequiredChecksPassed: inputChecks
        )

        var captures: [CaseCapture] = []
        for benchmark in Self.cases {
            let engineRuns = try await captureEngineRuns(
                benchmark,
                source: source,
                inputURL: inputURL,
                warmupCount: warmupCount,
                sampleCount: sampleCount
            )
            let endToEndRuns = try await captureEndToEndRuns(
                benchmark,
                inputURL: inputURL,
                expectedInput: inputInspection,
                warmupCount: warmupCount,
                sampleCount: sampleCount
            )
            captures.append(CaseCapture(
                id: benchmark.id,
                backendID: benchmark.backendID,
                targetWidth: benchmark.targetWidth,
                targetHeight: benchmark.targetHeight,
                request: RequestIdentity(
                    codec: OutputCodec.h264.rawValue,
                    fileType: "mov",
                    preserveAudio: false,
                    overwriteExistingFile: false
                ),
                engineRuns: engineRuns,
                endToEndRuns: endToEndRuns
            ))
        }

        let capture = Capture(
            schemaVersion: "mirmir-v4-performance-capture-v1",
            variant: try requiredEnvironment(
                "MIRMIR_V4_PERFORMANCE_VARIANT",
                in: environment
            ),
            contractSHA256: try requiredEnvironment(
                "MIRMIR_V4_PERFORMANCE_CONTRACT_SHA256",
                in: environment
            ),
            captureSourceSHA256: try requiredEnvironment(
                "MIRMIR_V4_PERFORMANCE_CAPTURE_SOURCE_SHA256",
                in: environment
            ),
            sourceIdentitySHA256: try requiredEnvironment(
                "MIRMIR_V4_PERFORMANCE_SOURCE_IDENTITY_SHA256",
                in: environment
            ),
            sourceRevision: try requiredEnvironment(
                "MIRMIR_V4_PERFORMANCE_SOURCE_REVISION",
                in: environment
            ),
            sourceTreeSHA256: try requiredEnvironment(
                "MIRMIR_V4_PERFORMANCE_SOURCE_TREE_SHA256",
                in: environment
            ),
            buildConfiguration: "Release",
            warmupCount: warmupCount,
            sampleCount: sampleCount,
            input: inputIdentity,
            evidenceRequestSHA256: requestSHA256,
            observerSourceSHA256: observerSourceSHA256,
            packagedCandidateIdentity: packageIdentity,
            cases: captures
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestURL = outputDirectory.appendingPathComponent("capture.json")
        try encoder.encode(capture).write(
            to: manifestURL,
            options: .atomic
        )
        return manifestURL
    }

    private static func captureEngineRuns(
        _ benchmark: BenchmarkCase,
        source: VideoInfo,
        inputURL: URL,
        warmupCount: Int,
        sampleCount: Int
    ) async throws -> [EngineRun] {
        let catalog = UpscaleBackendCatalog.live()
        let environment = RuntimeEnvironment.current()
        let request = BackendPreparationRequest(
            source: source,
            targetSize: CGSize(
                width: benchmark.targetWidth,
                height: benchmark.targetHeight
            )
        )
        let decoderProbe = try await catalog.prepare(
            backendID: benchmark.backend,
            request: request,
            environment: environment
        )
        let decoded = try await decodedSamples(
            at: inputURL,
            outputSettings: decoderProbe.sourcePixelBufferAttributes.values
        )
        try await decoderProbe.finish()
        try requireEqual(decoded.count, 3)

        var measured: [EngineRun] = []
        for iteration in 0..<(warmupCount + sampleCount) {
            let prepared = try await catalog.prepare(
                backendID: benchmark.backend,
                request: request,
                environment: environment
            )
            try requireEqual(prepared.actualBackendID, benchmark.backend)
            let pool = try makePool(prepared.destinationPixelBufferAttributes)
            var frameMilliseconds: [Double] = []
            for (frameIndex, sample) in decoded.enumerated() {
                let destination = try makeBuffer(pool)
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                let sampleDuration = CMSampleBufferGetDuration(sample)
                let duration = sampleDuration.isValid && sampleDuration.isNumeric
                    ? sampleDuration
                    : CMTime(value: 1, timescale: 30)
                let sourceBuffer = try unwrap(
                    CMSampleBufferGetImageBuffer(sample)
                )
                let started = DispatchTime.now().uptimeNanoseconds
                try await prepared.process(
                    source: sourceBuffer,
                    destination: destination,
                    timing: FrameTiming(
                        frameIndex: frameIndex,
                        presentationTime: presentationTime,
                        duration: duration
                    )
                )
                let finished = DispatchTime.now().uptimeNanoseconds
                if iteration >= warmupCount {
                    frameMilliseconds.append(
                        Double(finished - started) / 1_000_000.0
                    )
                }
            }
            try await prepared.finish()
            if iteration >= warmupCount {
                measured.append(EngineRun(
                    sampleIndex: iteration - warmupCount,
                    frameMilliseconds: frameMilliseconds,
                    processedFrameCount: frameMilliseconds.count
                ))
            }
        }
        return measured
    }

    private static func captureEndToEndRuns(
        _ benchmark: BenchmarkCase,
        inputURL: URL,
        expectedInput: AssetInspection,
        warmupCount: Int,
        sampleCount: Int
    ) async throws -> [EndToEndRun] {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-v4-performance-\(benchmark.id)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        var measured: [EndToEndRun] = []
        for iteration in 0..<(warmupCount + sampleCount) {
            let outputURL = temporaryRoot.appendingPathComponent(
                "run-\(iteration).mov"
            )
            let sampler = MirmirPackagedPeakResidentSamplerV4()
            let samplingTask = sampler.start()
            let started = DispatchTime.now().uptimeNanoseconds
            let result = try await UpscaleCoordinator().process(
                UpscaleRequest(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    backendID: benchmark.backend,
                    targetWidth: benchmark.targetWidth,
                    targetHeight: benchmark.targetHeight,
                    outputCodec: .h264,
                    preserveAudio: false,
                    overwriteExistingFile: false
                ),
                progress: { _ in }
            )
            let inspection = try await inspectAsset(outputURL, decodePixels: true)
            let verification = makeVerification(
                benchmark: benchmark,
                actualBackendID: result.actualBackendID,
                processedFrameCount: result.processedFrameCount,
                expectedInput: expectedInput,
                output: inspection
            )
            try requireTrue(
                verification.allRequiredChecksPassed,
                "semantic output verification failed for \(benchmark.id)"
            )
            let finished = DispatchTime.now().uptimeNanoseconds
            sampler.stop()
            await samplingTask.value
            if iteration >= warmupCount {
                measured.append(EndToEndRun(
                    sampleIndex: iteration - warmupCount,
                    wallMilliseconds: Double(finished - started) / 1_000_000.0,
                    peakResidentBytes: sampler.peakResidentBytes,
                    processedFrameCount: result.processedFrameCount,
                    verification: verification
                ))
            }
            try FileManager.default.removeItem(at: outputURL)
        }
        return measured
    }

    private static func makeVerification(
        benchmark: BenchmarkCase,
        actualBackendID: UpscaleBackendID,
        processedFrameCount: Int,
        expectedInput: AssetInspection,
        output: AssetInspection
    ) -> Verification {
        let requestedBackend = actualBackendID == benchmark.backend
        let tracksAccounted = expectedInput.trackCount == 1
            && output.trackCount == expectedInput.trackCount
        let exactVideoTracks = output.enabledVideoTrackCount
            == expectedInput.enabledVideoTrackCount
        let dimensions = output.width == benchmark.targetWidth
            && output.height == benchmark.targetHeight
        let codec = output.codecFourCC == "avc1"
        let frameCount = processedFrameCount == expectedInput.frameCount
            && output.frameCount == expectedInput.frameCount
        let timestamps = timesEqual(
            output.presentationTimes,
            expectedInput.presentationTimes
        )
        let duration = CMTimeCompare(output.duration, expectedInput.duration) == 0
        let color = isBT709(output)
        let all = requestedBackend && tracksAccounted && exactVideoTracks
            && dimensions && codec && frameCount && timestamps && duration
            && color
        return Verification(
            requestedBackendExecutedWithoutFallback: requestedBackend,
            allInputTracksAccounted: tracksAccounted,
            exactEnabledVideoTrackCount: exactVideoTracks,
            exactEncodedDimensions: dimensions,
            exactCodec: codec,
            exactFrameCount: frameCount,
            exactPresentationTimestamps: timestamps,
            exactDuration: duration,
            bt709ColorContract: color,
            decodedVisiblePixelSHA256: output.decodedVisiblePixelSHA256,
            semanticTrackManifestSHA256: output.semanticTrackManifestSHA256,
            allRequiredChecksPassed: all
        )
    }

    private static func inspectAsset(
        _ url: URL,
        decodePixels: Bool
    ) async throws -> AssetInspection {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.load(.tracks)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let enabled = try await withThrowingTaskGroup(of: Bool.self) { group in
            for track in videoTracks {
                group.addTask { try await track.load(.isEnabled) }
            }
            var count = 0
            for try await value in group where value { count += 1 }
            return count
        }
        let videoTrack = try unwrap(videoTracks.first)
        let formats = try await videoTrack.load(.formatDescriptions)
        let format = try unwrap(formats.first)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let duration = try await asset.load(.duration)
        let decoded = try await decodedInspection(asset: asset, track: videoTrack)
        let presentationTimes = decoded.presentationTimes
        let extensions = try unwrap(
            CMFormatDescriptionGetExtensions(format)
        ) as NSDictionary
        let primaries = String(describing:
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] ?? ""
        )
        let transfer = String(describing:
            extensions[kCMFormatDescriptionExtension_TransferFunction] ?? ""
        )
        let matrix = String(describing:
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] ?? ""
        )
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(format))
        let manifest = TrackManifest(
            trackCount: tracks.count,
            enabledVideoTrackCount: enabled,
            codecFourCC: codec,
            encodedWidth: Int(dimensions.width),
            encodedHeight: Int(dimensions.height),
            frameCount: presentationTimes.count,
            presentationTimes: presentationTimes.map(timeIdentity),
            duration: timeIdentity(duration),
            colorPrimaries: primaries,
            transferFunction: transfer,
            yCbCrMatrix: matrix
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let trackHash = sha256(try encoder.encode(manifest))
        let pixelHash = decodePixels
            ? decoded.visiblePixelSHA256
            : String(repeating: "0", count: 64)
        return AssetInspection(
            trackCount: tracks.count,
            enabledVideoTrackCount: enabled,
            codecFourCC: codec,
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            frameCount: presentationTimes.count,
            presentationTimes: presentationTimes,
            duration: duration,
            colorPrimaries: primaries,
            transferFunction: transfer,
            yCbCrMatrix: matrix,
            decodedVisiblePixelSHA256: pixelHash,
            semanticTrackManifestSHA256: trackHash
        )
    }

    private static func decodedSamples(
        at url: URL,
        outputSettings: [String: Any]
    ) async throws -> [CMSampleBuffer] {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.load(.tracks)
        let track = try unwrap(tracks.first { $0.mediaType == .video })
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = true
        try requireTrue(reader.canAdd(output))
        reader.add(output)
        try requireTrue(reader.startReading())
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() { samples.append(sample) }
        try requireEqual(reader.status, .completed)
        return samples
    }

    private static func decodedInspection(
        asset: AVAsset,
        track: AVAssetTrack
    ) async throws -> DecodedInspection {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        output.alwaysCopiesSampleData = true
        try requireTrue(reader.canAdd(output))
        reader.add(output)
        try requireTrue(reader.startReading())
        var digest = SHA256()
        var presentationTimes: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            presentationTimes.append(presentationTime)
            let time = timeIdentity(presentationTime)
            digest.update(data: Data(time.utf8))
            let buffer = try unwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let planeCount = CVPixelBufferGetPlaneCount(buffer)
            for plane in 0..<planeCount {
                let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
                let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let visibleBytes = width * (plane == 0 ? 1 : 2)
                let base = try unwrap(
                    CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
                ).assumingMemoryBound(to: UInt8.self)
                for row in 0..<height {
                    digest.update(data: Data(
                        bytes: base.advanced(by: row * stride),
                        count: visibleBytes
                    ))
                }
            }
        }
        try requireEqual(reader.status, .completed)
        try requireEqual(presentationTimes.count, 3)
        return DecodedInspection(
            presentationTimes: presentationTimes,
            visiblePixelSHA256: digest.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    private static func makePool(_ attributes: PixelBufferAttributes) throws
        -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
            attributes.values as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return pool
    }

    private static func makeBuffer(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return buffer
    }

    private static func isBT709(_ inspection: AssetInspection) -> Bool {
        inspection.colorPrimaries.contains("709")
            && inspection.transferFunction.contains("709")
            && inspection.yCbCrMatrix.contains("709")
    }

    private static func timesEqual(_ lhs: [CMTime], _ rhs: [CMTime]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            CMTimeCompare($0, $1) == 0
        }
    }

    private static func timeIdentity(_ time: CMTime) -> String {
        guard time.isValid && time.isNumeric else { return "invalid" }
        let normalized = time.convertScale(600_000, method: .default)
        return "\(normalized.value)/\(normalized.timescale)"
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????????"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func requiredEnvironment(
        _ name: String,
        in environment: [String: String]
    ) throws -> String {
        guard let value = environment[name], !value.isEmpty else {
            throw MirmirPackagedEvidenceErrorV4.capture(
                "missing performance setting \(name)"
            )
        }
        return value
    }

    private static func positiveIntegerEnvironment(
        _ name: String,
        minimum: Int,
        in environment: [String: String]
    ) throws -> Int {
        let text = try requiredEnvironment(name, in: environment)
        guard let value = Int(text), value >= minimum else {
            throw MirmirPackagedEvidenceErrorV4.capture(
                "\(name) must be at least \(minimum)"
            )
        }
        return value
    }

    private static func unwrap<T>(
        _ value: T?,
        _ message: String = "required performance value is absent"
    ) throws -> T {
        guard let value else {
            throw MirmirPackagedEvidenceErrorV4.capture(message)
        }
        return value
    }

    private static func requireTrue(
        _ condition: @autoclosure () -> Bool,
        _ message: String = "performance assertion failed"
    ) throws {
        guard condition() else {
            throw MirmirPackagedEvidenceErrorV4.capture(message)
        }
    }

    private static func requireEqual<T: Equatable>(
        _ lhs: @autoclosure () -> T,
        _ rhs: @autoclosure () -> T,
        _ message: String = "performance equality assertion failed"
    ) throws {
        guard lhs() == rhs() else {
            throw MirmirPackagedEvidenceErrorV4.capture(message)
        }
    }

}

@available(macOS 15.4, *)
private final class MirmirPackagedPeakResidentSamplerV4: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var peak: UInt64 = 0

    var peakResidentBytes: UInt64 {
        lock.withLock { peak }
    }

    func start() -> Task<Void, Never> {
        lock.withLock {
            stopped = false
            peak = max(peak, currentResidentBytes())
        }
        return Task.detached { [self] in
            while !lock.withLock({ stopped }) {
                let resident = currentResidentBytes()
                lock.withLock { peak = max(peak, resident) }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            let resident = currentResidentBytes()
            lock.withLock { peak = max(peak, resident) }
        }
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    private func currentResidentBytes() -> UInt64 {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
            }
        }
        return result == 0 ? usage.ri_resident_size : 0
    }
}
