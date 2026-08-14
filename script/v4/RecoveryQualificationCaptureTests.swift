import Foundation
import XCTest
@testable import Mirmir

/// Compile and implementation-smoke wrapper for the production recovery
/// producer. Release qualification never accepts this XCTest process as the
/// normative scenario producer; the sealed application executable owns that
/// role.
@available(macOS 15.4, *)
final class DeterministicEngineV4RecoveryQualificationCaptureTests:
    XCTestCase
{
    func testCaptureRecoveryQualificationWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["MIRMIR_V4_RECOVERY_CAPTURE_DIR"],
              !output.isEmpty else {
            return
        }
        let producer = RecoveryQualificationProducerV4()
        _ = try await producer.capture(RecoveryQualificationCaptureRequestV4(
            captureRootURL: URL(
                fileURLWithPath: output,
                isDirectory: true
            ),
            contractURL: URL(fileURLWithPath: try required(
                "MIRMIR_V4_RECOVERY_CONTRACT",
                environment
            )),
            contractSHA256: try required(
                "MIRMIR_V4_RECOVERY_CONTRACT_SHA256",
                environment
            ),
            producerSourceSHA256: try required(
                "MIRMIR_V4_RECOVERY_PRODUCER_SOURCE_SHA256",
                environment
            ),
            execution: RecoveryQualificationPackagedExecutionV4(
                requestID: environment[
                    "MIRMIR_V4_RECOVERY_REQUEST_ID"
                ] ?? "11111111-1111-1111-1111-111111111111",
                requestSHA256: identity(
                    "MIRMIR_V4_RECOVERY_REQUEST_SHA256",
                    environment,
                    fallback: 1
                ),
                nonceSHA256: identity(
                    "MIRMIR_V4_RECOVERY_NONCE_SHA256",
                    environment,
                    fallback: 2
                ),
                observerSourceSHA256: identity(
                    "MIRMIR_V4_RECOVERY_OBSERVER_SOURCE_SHA256",
                    environment,
                    fallback: 3
                ),
                packageIdentity: fixturePackageIdentity(environment)
            )
        ))
    }

    private func fixturePackageIdentity(
        _ environment: [String: String]
    ) -> RecoveryQualificationPackageIdentityV4 {
        RecoveryQualificationPackageIdentityV4(
            schemaVersion: "mirmir-v4-packaged-candidate-identity-v1",
            buildConfiguration: "Release",
            applicationArchiveSHA256: identity(
                "MIRMIR_V4_RECOVERY_ARCHIVE_SHA256",
                environment,
                fallback: 4
            ),
            applicationPayloadIdentitySHA256: identity(
                "MIRMIR_V4_RECOVERY_PAYLOAD_SHA256",
                environment,
                fallback: 5
            ),
            applicationInfoPlistSHA256: identity(
                "MIRMIR_V4_RECOVERY_INFO_PLIST_SHA256",
                environment,
                fallback: 6
            ),
            applicationExecutableSHA256: identity(
                "MIRMIR_V4_RECOVERY_EXECUTABLE_SHA256",
                environment,
                fallback: 7
            ),
            codeDirectories: [
                RecoveryQualificationCodeDirectoryV4(
                    architecture: "arm64",
                    sha256: identity(
                        "MIRMIR_V4_RECOVERY_ARM64_CODE_DIRECTORY_SHA256",
                        environment,
                        fallback: 8
                    )
                ),
                RecoveryQualificationCodeDirectoryV4(
                    architecture: "x86_64",
                    sha256: identity(
                        "MIRMIR_V4_RECOVERY_X86_64_CODE_DIRECTORY_SHA256",
                        environment,
                        fallback: 9
                    )
                ),
            ],
            codeDirectorySetSHA256: identity(
                "MIRMIR_V4_RECOVERY_CODE_DIRECTORY_SET_SHA256",
                environment,
                fallback: 10
            ),
            designatedRequirementSHA256: identity(
                "MIRMIR_V4_RECOVERY_REQUIREMENT_SHA256",
                environment,
                fallback: 11
            ),
            releaseConfigurationSHA256: identity(
                "MIRMIR_V4_RECOVERY_CONFIGURATION_SHA256",
                environment,
                fallback: 12
            ),
            attestationSHA256: identity(
                "MIRMIR_V4_RECOVERY_ATTESTATION_SHA256",
                environment,
                fallback: 13
            ),
            sourceCommit: environment[
                "MIRMIR_V4_RECOVERY_SOURCE_COMMIT"
            ] ?? String(repeating: "1", count: 40),
            sourceTreeIdentitySHA256: identity(
                "MIRMIR_V4_RECOVERY_SOURCE_TREE_SHA256",
                environment,
                fallback: 14
            ),
            runtimeManifestSHA256: identity(
                "MIRMIR_V4_RECOVERY_RUNTIME_MANIFEST_SHA256",
                environment,
                fallback: 15
            ),
            runtimeManifestFileSHA256: identity(
                "MIRMIR_V4_RECOVERY_RUNTIME_MANIFEST_FILE_SHA256",
                environment,
                fallback: 16
            ),
            runtimeArtifactSetSHA256: identity(
                "MIRMIR_V4_RECOVERY_RUNTIME_ARTIFACT_SET_SHA256",
                environment,
                fallback: 17
            ),
            runtimeSourceRevision: environment[
                "MIRMIR_V4_RECOVERY_RUNTIME_SOURCE_REVISION"
            ] ?? String(repeating: "2", count: 40),
            bundleIdentifier: "com.mirmir.app",
            productVersion: "4.0",
            productBuild: "400"
        )
    }

    private func required(
        _ key: String,
        _ environment: [String: String]
    ) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw NSError(
                domain: "MirmirRecoveryProducerSmoke",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing value \(key)."]
            )
        }
        return value
    }

    private func identity(
        _ key: String,
        _ environment: [String: String],
        fallback: Int
    ) -> String {
        environment[key] ?? String(format: "%064llx", fallback)
    }
}
