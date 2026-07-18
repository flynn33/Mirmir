import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
@preconcurrency import Metal

// The native evidence support keeps its fail-closed identity checks together.
// swiftlint:disable file_length type_body_length

enum ASHP08NativeError: Error, CustomStringConvertible {
    case missingEnvironment(String)
    case invalidEnvironment(String)
    case invalidPath(String)
    case invalidArtifact(String)
    case invalidFixture(String)
    case mediaFailure(String)
    case metalUnavailable
    case outputExists(String)

    var description: String {
        switch self {
        case .missingEnvironment(let name):
            "required environment variable is absent: \(name)"
        case .invalidEnvironment(let name):
            "environment variable violates its contract: \(name)"
        case .invalidPath(let message):
            "path contract violation: \(message)"
        case .invalidArtifact(let message):
            "artifact contract violation: \(message)"
        case .invalidFixture(let message):
            "fixture contract violation: \(message)"
        case .mediaFailure(let message):
            "AVFoundation measurement failure: \(message)"
        case .metalUnavailable:
            "the P08 producer requires a Metal device"
        case .outputExists(let path):
            "output path already exists: \(path)"
        }
    }
}

struct ASHP08DecodedFrame: @unchecked Sendable {
    let ordinal: Int
    let presentationTimestamp: CMTime
    let pixelBuffer: CVPixelBuffer
    let decodedNV12SHA256: String
    let yPlaneSHA256: String
    let cbcrPlaneSHA256: String

    var binding: [String: Any] {
        [
            "frame_ordinal": ordinal,
            "presentation_timestamp_value": presentationTimestamp.value,
            "presentation_timestamp_timescale": presentationTimestamp.timescale,
            "decoded_nv12_sha256": decodedNV12SHA256,
            "y_plane_sha256": yPlaneSHA256,
            "cbcr_plane_sha256": cbcrPlaneSHA256
        ]
    }
}

struct ASHP08Fixture: @unchecked Sendable {
    let route: ASHSpatialRouteV2
    let url: URL
    let fileSHA256: String
    let sourceWidth: Int
    let sourceHeight: Int
    let destinationWidth: Int
    let destinationHeight: Int
    let frames: [ASHP08DecodedFrame]

    var fixtureID: String { url.lastPathComponent }

    func benchmarkConditions(mode: String) throws -> [String: Any] {
        guard mode == "compute_only" || mode == "end_to_end" else {
            throw ASHP08NativeError.invalidArtifact("unknown benchmark mode \(mode)")
        }
        let bitRate = ProductVideoOutputSettings.estimatedBitRate(
            width: destinationWidth,
            height: destinationHeight,
            codec: .hevc
        )
        return [
            "fixture_id": fixtureID,
            "fixture_file_sha256": fileSHA256,
            "source_width": sourceWidth,
            "source_height": sourceHeight,
            "destination_width": destinationWidth,
            "destination_height": destinationHeight,
            "fixture_frame_count": frames.count,
            "ordered_decoded_frames": frames.map(\.binding),
            "decoded_pixel_format_fourcc": "420v",
            "decoded_plane_layout": "NV12",
            "code_range": "video",
            "chroma_location": "left",
            "color_primaries": "ITU_R_709_2",
            "transfer_function": "ITU_R_709_2",
            "ycbcr_matrix": "ITU_R_709_2",
            "frame_repetition": [
                "rule": "cyclic in original presentation order with generated benchmark timestamps",
                "generated_timestamp_start_value": 0,
                "generated_timestamp_step_value": 1,
                "generated_timestamp_timescale": 60,
                "cpu_reference_frames": 3,
                "warmup_frames": 30,
                "measurement_frames": 300
            ],
            "measurement_scope": mode,
            "writer_settings": [
                "execution_scope": mode == "compute_only"
                    ? "not_executed_compute_only" : "production_end_to_end",
                "framework": "AVFoundation",
                "container": "mp4",
                "codec": "hevc",
                "expected_frame_rate": ProductVideoOutputSettings.expectedFrameRate,
                "average_bit_rate": bitRate,
                "expects_media_data_in_real_time": false,
                "pixel_format": "420v",
                "color_primaries": "ITU_R_709_2",
                "transfer_function": "ITU_R_709_2",
                "ycbcr_matrix": "ITU_R_709_2"
            ]
        ]
    }
}

@available(macOS 15.4, *)
struct ASHP08NativeContext: @unchecked Sendable {
    let runID: String
    let artifacts: ASHLockedArtifactSetV3
    let metal: DefaultMetalRenderingService
    let device: [String: Any]
    let deviceIdentitySHA256: String
    let executionIdentity: [String: Any]
    let selectedEvaluationArtifactSHA256: String
    let calibrationEstimatedDispatchCost: Double
    let bestFixedDescriptorID: UInt8
}

@available(macOS 15.4, *)
enum ASHP08NativeSupport {
    static let fixedControlSelectionSchemaSHA256 =
        "543db7e687bb7bcbdbb987b3c53c575d7a24a9473487098608601e9661fa2db1"

    static let resourceFilenames = [
        "lut-manifest-v3.json",
        "locked-compiler-input-v2.json",
        "locked-mapping.json",
        "direct2x.ashlut",
        "direct3over2.ashlut",
        "native-lut-parity-manifest-v3.json"
    ]

    static let hashScope =
        "canonical sorted-key compact UTF-8 JSON excluding /artifact_sha256"

    private static let fixtureSHA256: [ASHSpatialRouteV2: String] = [
        .direct2x: "fd07d42fa717c64abb26af145dd156b7479f2df29f9d151904ec2f62e88b22ae",
        .direct3Over2: "219ae4f012a50d4f22a515544fd1f05aa0ff933782a45fc0b779437b9414dce0"
    ]

    private static let sha256Pattern = regularExpression(
        "^(?!0{64}$)[0-9a-f]{64}$"
    )
    private static let commitPattern = regularExpression(
        "^(?!0{40}$)[0-9a-f]{40}$"
    )
    private static let runIDPattern = regularExpression(
        "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
    )

    // One atomic reopen prevents partially validated execution identities.
    // swiftlint:disable:next function_body_length
    static func loadContext() async throws -> ASHP08NativeContext {
        let runID = try environment("MIRMIR_P08_RUN_ID", pattern: runIDPattern)
        let sourceCommit = try environment(
            "MIRMIR_P08_SOURCE_COMMIT",
            pattern: commitPattern
        )
        let sourceTreeSHA256 = try environment(
            "MIRMIR_P08_SOURCE_TREE_SHA256",
            pattern: sha256Pattern
        )
        let expectedAppTreeSHA256 = try environment(
            "MIRMIR_P08_PRODUCTION_APP_TREE_SHA256",
            pattern: sha256Pattern
        )
        let observedAppTreeSHA256 = try productionAppTreeSHA256()
        guard observedAppTreeSHA256 == expectedAppTreeSHA256 else {
            throw ASHP08NativeError.invalidArtifact(
                "production app tree differs from the external pre-launch binding"
            )
        }
        let externalRoot = try absoluteDirectory(
            environment("MIRMIR_P08_P06_RELEASE_ROOT")
        )
        let bundledRoot = try bundledResourceRoot()
        let bundledResources = try verifyExactReleaseResources(
            bundledRoot: bundledRoot,
            externalRoot: externalRoot
        )
        let artifacts = try await ASHLockedArtifactStoreV3(
            resourceRoot: bundledRoot
        ).artifacts()

        let releaseBundleURL = try absoluteRegularFile(
            environment("MIRMIR_P08_P06_RELEASE_BUNDLE_FILE")
        )
        let releaseArtifactRoot = try absoluteDirectory(
            releaseBundleURL.deletingLastPathComponent().path
        )
        let releaseBundle = try verifiedCanonicalArtifact(
            at: releaseBundleURL,
            hashField: "artifact_sha256"
        )
        guard let releaseHash = releaseBundle["artifact_sha256"] as? String,
              releaseBundle["configuration_id"] as? String
                == artifacts.configuration.configurationID else {
            throw ASHP08NativeError.invalidArtifact(
                "P06 release bundle identity differs from bundled configuration"
            )
        }

        let selectedURL = try absoluteRegularFile(
            environment("MIRMIR_P08_SELECTED_EVALUATION_FILE")
        )
        guard let releaseArtifactRows = releaseBundle["artifacts"] as? [[String: Any]],
              let selectedReleaseBinding = releaseArtifactRows.first(where: {
                $0["id"] as? String == "selected_evaluation"
              }) else {
            throw ASHP08NativeError.invalidArtifact(
                "P06 release bundle does not bind the selected evaluation"
            )
        }
        try verifyReleaseFileBinding(
            selectedReleaseBinding,
            artifactRoot: releaseArtifactRoot,
            expectedURL: selectedURL,
            expectedID: "selected_evaluation"
        )
        let selected = try verifiedCanonicalArtifact(
            at: selectedURL,
            hashField: "artifact_sha256"
        )
        guard let selectedHash = selected["artifact_sha256"] as? String,
              let evaluation = selected["evaluation"] as? [String: Any],
              let objective = evaluation["objective"] as? [String: Any],
              let dispatchCost = number(objective["estimated_dispatch_cost"]),
              dispatchCost > 0 else {
            throw ASHP08NativeError.invalidArtifact(
                "selected evaluation lacks a positive evaluation/objective/estimated_dispatch_cost"
            )
        }
        guard let authorizationBinding = selected["control_authorization_bundle"]
                as? [String: Any],
              let authorizationURL = try? absoluteRegularFile(
                environment("MIRMIR_P08_CONTROL_AUTHORIZATION_BUNDLE_FILE")
              ) else {
            throw ASHP08NativeError.invalidArtifact(
                "selected evaluation lacks its control-authorization binding"
            )
        }
        let controlAuthorization = try verifiedTypedArtifact(
            binding: authorizationBinding,
            artifactRoot: releaseArtifactRoot,
            expectedURL: authorizationURL,
            expectedKind: "p06_control_authorization_bundle_v2",
            expectedSchemaSHA256:
                "c5d79fa2b6b8b574532d4a83d95a4e543f6a9dde769bc8c3f3969d5167729582"
        )
        guard let controlSelections = controlAuthorization["control_selections"]
                as? [[String: Any]],
              controlSelections.count == 3,
              controlSelections[0]["id"] as? String == "best_fixed",
              let fixedBinding = controlSelections[0]["selection"] as? [String: Any]
        else {
            throw ASHP08NativeError.invalidArtifact(
                "selected evaluation does not transitively bind the control authorization bundle"
            )
        }
        let fixedURL = try absoluteRegularFile(
            environment("MIRMIR_P08_BEST_FIXED_SELECTION_FILE")
        )
        let fixedSelection = try verifiedTypedArtifact(
            binding: fixedBinding,
            artifactRoot: releaseArtifactRoot,
            expectedURL: fixedURL,
            expectedKind: "p06_fixed_control_selection_v2",
            expectedSchemaSHA256: fixedControlSelectionSchemaSHA256
        )
        guard fixedSelection["selection_stage"] as? String == "validation_final",
              fixedSelection["split"] as? String == "validation",
              let descriptorNumber = fixedSelection["chosen_descriptor_id"] as? NSNumber,
              descriptorNumber.intValue >= 0,
              descriptorNumber.intValue < Int(ASHSpatialDescriptorV2.count) else {
            throw ASHP08NativeError.invalidArtifact(
                "authorized best-fixed selection is absent, unbound, or non-final"
            )
        }
        let bestFixedDescriptorID = UInt8(descriptorNumber.intValue)

        let metal = try DefaultMetalRenderingService()
        let device = try deviceIdentity(metal.device)
        let deviceIdentitySHA256 = try canonicalSHA256(device)
        let executable = try absoluteRegularFile(
            Bundle.main.executableURL ?? URL(fileURLWithPath: "")
        )
        guard let metalLibraryCandidate = Bundle.main.url(
            forResource: "default",
            withExtension: "metallib"
        ) else {
            throw ASHP08NativeError.invalidArtifact("default.metallib is absent")
        }
        let metalLibrary = try absoluteRegularFile(metalLibraryCandidate)
        let executionIdentity: [String: Any] = [
            "source_commit": sourceCommit,
            "source_tree_sha256": sourceTreeSHA256,
            "configuration_id": artifacts.configuration.configurationID,
            "p06_release_bundle_artifact_sha256": releaseHash,
            "selected_evaluation_artifact_sha256": selectedHash,
            "g07_publication_manifest_sha256": NSNull(),
            "holdout_accessed": false,
            "production_app_tree_sha256": observedAppTreeSHA256,
            "production_executable_sha256": try sha256(executable),
            "metal_library_sha256": try sha256(metalLibrary),
            "bundled_release_resources": bundledResources
        ]
        return ASHP08NativeContext(
            runID: runID,
            artifacts: artifacts,
            metal: metal,
            device: device,
            deviceIdentitySHA256: deviceIdentitySHA256,
            executionIdentity: executionIdentity,
            selectedEvaluationArtifactSHA256: selectedHash,
            calibrationEstimatedDispatchCost: dispatchCost,
            bestFixedDescriptorID: bestFixedDescriptorID
        )
    }

    static func loadFixture(_ route: ASHSpatialRouteV2) async throws -> ASHP08Fixture {
        // The tuple is a closed local description of the two preregistered routes.
        // swiftlint:disable:next large_tuple
        let contract: (
            environment: String,
            filename: String,
            sourceWidth: Int,
            sourceHeight: Int,
            destinationWidth: Int,
            destinationHeight: Int,
            frameCount: Int
        )
        switch route {
        case .direct2x:
            contract = (
                "MIRMIR_P08_DIRECT2X_FIXTURE",
                "img9200_exact_1080p_3f.mp4",
                1_920, 1_080, 3_840, 2_160, 3
            )
        case .direct3Over2:
            contract = (
                "MIRMIR_P08_DIRECT3OVER2_FIXTURE",
                "img9200_exact_720p_1f.mp4",
                1_280, 720, 1_920, 1_080, 1
            )
        }
        let url = try absoluteRegularFile(environment(contract.environment))
        guard url.lastPathComponent == contract.filename else {
            throw ASHP08NativeError.invalidFixture(
                "\(contract.environment) must name \(contract.filename)"
            )
        }
        let observedFileSHA256 = try sha256(url)
        guard observedFileSHA256 == fixtureSHA256[route] else {
            throw ASHP08NativeError.invalidFixture(
                "\(contract.filename) SHA-256 differs from the preregistered fixture bytes"
            )
        }
        let frames = try await decodeFrames(
            url,
            expectedWidth: contract.sourceWidth,
            expectedHeight: contract.sourceHeight
        )
        guard frames.count == contract.frameCount else {
            throw ASHP08NativeError.invalidFixture(
                "\(contract.filename) decoded \(frames.count) frames; expected \(contract.frameCount)"
            )
        }
        if route == .direct2x {
            let observed = frames.map {
                ($0.presentationTimestamp.value, $0.presentationTimestamp.timescale)
            }
            guard observed.elementsEqual([(0, 60), (1, 60), (2, 60)], by: ==) else {
                throw ASHP08NativeError.invalidFixture(
                    "direct-2x fixture timestamps are not exactly 0/60, 1/60, 2/60"
                )
            }
        } else {
            guard frames[0].presentationTimestamp.value == 0 else {
                throw ASHP08NativeError.invalidFixture(
                    "direct-3-over-2 fixture does not begin at presentation timestamp zero"
                )
            }
        }
        guard try sha256(url) == observedFileSHA256 else {
            throw ASHP08NativeError.invalidFixture(
                "\(contract.filename) changed while it was decoded"
            )
        }
        return ASHP08Fixture(
            route: route,
            url: url,
            fileSHA256: observedFileSHA256,
            sourceWidth: contract.sourceWidth,
            sourceHeight: contract.sourceHeight,
            destinationWidth: contract.destinationWidth,
            destinationHeight: contract.destinationHeight,
            frames: frames
        )
    }

    static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw ASHP08NativeError.mediaFailure(
                "CVPixelBufferCreate failed with status \(status)"
            )
        }
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        return pixelBuffer
    }

    static func activePlaneData(
        _ pixelBuffer: CVPixelBuffer,
        plane: Int
    ) throws -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard plane >= 0,
              plane < CVPixelBufferGetPlaneCount(pixelBuffer),
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
            throw ASHP08NativeError.mediaFailure("missing NV12 plane \(plane)")
        }
        let rowCount = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let activeBytesPerRow = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            * (plane == 0 ? 1 : 2)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var output = Data(capacity: activeBytesPerRow * rowCount)
        for row in 0..<rowCount {
            output.append(
                bytes.advanced(by: row * stride),
                count: activeBytesPerRow
            )
        }
        return output
    }

    static func pixelBufferSHA256(_ pixelBuffer: CVPixelBuffer) throws -> String {
        var data = try activePlaneData(pixelBuffer, plane: 0)
        data.append(try activePlaneData(pixelBuffer, plane: 1))
        return sha256(data)
    }

    static func residentMemoryBytes() throws -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw ASHP08NativeError.invalidArtifact(
                "task_info(MACH_TASK_BASIC_INFO) failed: \(result)"
            )
        }
        return Int(info.resident_size)
    }

    static func canonicalData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ASHP08NativeError.invalidArtifact(
                "document is outside the JSON value domain"
            )
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func canonicalSHA256(_ object: Any) throws -> String {
        sha256(try canonicalData(object))
    }

    static func productionAppTreeSHA256() throws -> String {
        let app = try absoluteDirectory(Bundle.main.bundleURL.path)
        guard app.pathExtension == "app", app.lastPathComponent == "Mirmir.app" else {
            throw ASHP08NativeError.invalidArtifact(
                "P08 execution is not inside the ordinary Mirmir.app bundle"
            )
        }
        let plugins = app
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("PlugIns", isDirectory: true)
        var pluginMetadata = stat()
        guard lstat(plugins.path, &pluginMetadata) != 0, errno == ENOENT else {
            throw ASHP08NativeError.invalidArtifact(
                "production app contains a hosted test PlugIns tree"
            )
        }

        var records: [[String: Any]] = []
        var fileCount = 0
        var totalSize = 0
        try appendTreeInventory(
            directory: app,
            root: app,
            records: &records,
            fileCount: &fileCount,
            totalSize: &totalSize
        )
        guard fileCount > 0, totalSize > 0 else {
            throw ASHP08NativeError.invalidArtifact(
                "production app tree has no nonempty file evidence"
            )
        }
        guard records.allSatisfy({
            $0["path"] is String && $0["kind"] is String
        }) else {
            throw ASHP08NativeError.invalidArtifact(
                "production app inventory contains an untyped record"
            )
        }
        records.sort {
            let lhsPath = $0["path"] as? String ?? ""
            let rhsPath = $1["path"] as? String ?? ""
            if lhsPath != rhsPath { return lhsPath < rhsPath }
            return ($0["kind"] as? String ?? "") < ($1["kind"] as? String ?? "")
        }
        return try canonicalSHA256(records)
    }

    static func finalizedDocument(_ document: [String: Any]) throws -> [String: Any] {
        guard document["artifact_sha256"] == nil else {
            throw ASHP08NativeError.invalidArtifact(
                "artifact_sha256 must be absent before finalization"
            )
        }
        var finalized = document
        finalized["artifact_sha256"] = try canonicalSHA256(document)
        return finalized
    }

    static func writeNewDocument(
        _ document: [String: Any],
        environmentName: String
    ) throws {
        let output = try absoluteOutputFile(environment(environmentName))
        if FileManager.default.fileExists(atPath: output.path) {
            throw ASHP08NativeError.outputExists(output.path)
        }
        let finalized = try finalizedDocument(document)
        var bytes = try canonicalData(finalized)
        bytes.append(0x0a)
        try bytes.write(to: output, options: [.atomic, .withoutOverwriting])
        guard try Data(contentsOf: output) == bytes else {
            throw ASHP08NativeError.invalidArtifact(
                "reopened output differs from the written canonical bytes"
            )
        }
    }

    static func readFinalizedDocument(
        environmentName: String
    ) throws -> [String: Any] {
        try verifiedCanonicalArtifact(
            at: absoluteRegularFile(environment(environmentName)),
            hashField: "artifact_sha256"
        )
    }

    static func verifiedTypedArtifact(
        binding: [String: Any],
        artifactRoot: URL,
        expectedURL: URL,
        expectedKind: String,
        expectedSchemaSHA256: String? = nil
    ) throws -> [String: Any] {
        guard Set(binding.keys) == Set([
            "artifact_kind", "schema_sha256", "path", "sha256", "size_bytes"
        ]),
        binding["artifact_kind"] as? String == expectedKind,
        let schemaSHA256 = binding["schema_sha256"] as? String,
        matches(schemaSHA256, pattern: sha256Pattern),
        expectedSchemaSHA256 == nil || schemaSHA256 == expectedSchemaSHA256,
        let expectedFileSHA256 = binding["sha256"] as? String,
        matches(expectedFileSHA256, pattern: sha256Pattern),
        let expectedSize = binding["size_bytes"] as? NSNumber,
        expectedSize.intValue > 0 else {
            throw ASHP08NativeError.invalidArtifact(
                "typed artifact binding fields differ: \(expectedKind)"
            )
        }
        let url = try boundArtifactURL(
            binding: binding,
            artifactRoot: artifactRoot,
            expectedURL: expectedURL
        )
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count == expectedSize.intValue,
              sha256(bytes) == expectedFileSHA256 else {
            throw ASHP08NativeError.invalidArtifact(
                "typed artifact complete-file binding differs: \(expectedKind)"
            )
        }
        let document = try verifiedCanonicalArtifact(
            at: url,
            hashField: "artifact_sha256"
        )
        guard document["artifact_kind"] as? String == expectedKind else {
            throw ASHP08NativeError.invalidArtifact(
                "typed artifact document kind differs: \(expectedKind)"
            )
        }
        return document
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ url: URL) throws -> String {
        sha256(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func environment(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw ASHP08NativeError.missingEnvironment(name)
        }
        return value
    }

    static func percentile95(_ values: [Double]) throws -> Double {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else {
            throw ASHP08NativeError.invalidArtifact("invalid percentile input")
        }
        let sorted = values.sorted()
        let position = Double(sorted.count - 1) * 0.95
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    private static func environment(
        _ name: String,
        pattern: NSRegularExpression
    ) throws -> String {
        let value = try environment(name)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard pattern.firstMatch(in: value, range: range)?.range == range else {
            throw ASHP08NativeError.invalidEnvironment(name)
        }
        return value
    }

    private static func matches(
        _ value: String,
        pattern: NSRegularExpression
    ) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return pattern.firstMatch(in: value, range: range)?.range == range
    }

    private static func regularExpression(_ pattern: String) -> NSRegularExpression {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("invalid internal P08 regular expression")
        }
        return expression
    }

    private static func boundArtifactURL(
        binding: [String: Any],
        artifactRoot: URL,
        expectedURL: URL
    ) throws -> URL {
        guard let relative = binding["path"] as? String,
              !relative.isEmpty,
              !relative.hasPrefix("/"),
              !relative.hasSuffix("/"),
              !relative.contains("\\"),
              !relative.contains("//"),
              relative.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/")
                    .contains($0)
              }),
              relative.split(separator: "/").allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw ASHP08NativeError.invalidArtifact("typed artifact path is unsafe")
        }
        let root = try absoluteDirectory(artifactRoot.path)
        let candidate = root.appendingPathComponent(relative)
        guard candidate.standardizedFileURL.path == candidate.path,
              candidate.path.hasPrefix(root.path + "/"),
              candidate.path == expectedURL.path else {
            throw ASHP08NativeError.invalidArtifact(
                "typed artifact path differs from its release-root binding"
            )
        }
        return try absoluteRegularFile(candidate)
    }

    private static func verifyReleaseFileBinding(
        _ binding: [String: Any],
        artifactRoot: URL,
        expectedURL: URL,
        expectedID: String
    ) throws {
        guard binding["id"] as? String == expectedID,
              let expectedSHA256 = binding["sha256"] as? String,
              matches(expectedSHA256, pattern: sha256Pattern),
              let expectedSize = binding["size_bytes"] as? NSNumber,
              expectedSize.intValue > 0 else {
            throw ASHP08NativeError.invalidArtifact(
                "P06 release file binding fields differ: \(expectedID)"
            )
        }
        let url = try boundArtifactURL(
            binding: binding,
            artifactRoot: artifactRoot,
            expectedURL: expectedURL
        )
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count == expectedSize.intValue,
              sha256(bytes) == expectedSHA256 else {
            throw ASHP08NativeError.invalidArtifact(
                "P06 release complete-file binding differs: \(expectedID)"
            )
        }
    }

    private static func appendTreeInventory(
        directory: URL,
        root: URL,
        records: inout [[String: Any]],
        fileCount: inout Int,
        totalSize: inout Int
    ) throws {
        let entries = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for entry in entries {
            var metadata = stat()
            guard lstat(entry.path, &metadata) == 0 else {
                throw ASHP08NativeError.invalidArtifact(
                    "production app member could not be reopened: \(entry.path)"
                )
            }
            let relative = String(entry.path.dropFirst(root.path.count + 1))
            let kind = metadata.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFDIR) {
                records.append(["kind": "directory", "path": relative])
                try appendTreeInventory(
                    directory: entry,
                    root: root,
                    records: &records,
                    fileCount: &fileCount,
                    totalSize: &totalSize
                )
            } else if kind == mode_t(S_IFREG), metadata.st_nlink == 1 {
                let payload = try Data(contentsOf: entry, options: .mappedIfSafe)
                guard payload.count == Int(metadata.st_size) else {
                    throw ASHP08NativeError.invalidArtifact(
                        "production app member changed while hashing: \(relative)"
                    )
                }
                records.append([
                    "kind": "file",
                    "path": relative,
                    "sha256": sha256(payload),
                    "size_bytes": payload.count
                ])
                fileCount += 1
                totalSize += payload.count
            } else {
                throw ASHP08NativeError.invalidArtifact(
                    "production app contains a linked or special member: \(relative)"
                )
            }
        }
    }

    private static func absoluteOutputFile(_ value: String) throws -> URL {
        let url = URL(fileURLWithPath: value)
        guard url.path == value, url.path.hasPrefix("/") else {
            throw ASHP08NativeError.invalidPath("output must be an absolute normalized path")
        }
        let parent = url.deletingLastPathComponent()
        _ = try absoluteDirectory(parent.path)
        let leafValues = try? url.resourceValues(forKeys: [
            .isSymbolicLinkKey, .isAliasFileKey
        ])
        guard leafValues?.isSymbolicLink != true,
              leafValues?.isAliasFile != true else {
            throw ASHP08NativeError.invalidPath("output leaf is a symlink or alias")
        }
        return url
    }

    private static func absoluteDirectory(_ value: String) throws -> URL {
        let url = URL(fileURLWithPath: value)
        guard url.path == value, url.path.hasPrefix("/") else {
            throw ASHP08NativeError.invalidPath("directory must be an absolute normalized path")
        }
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isAliasFile != true else {
            throw ASHP08NativeError.invalidPath(
                "directory is absent, non-directory, symlink, or alias: \(value)"
            )
        }
        return url
    }

    private static func absoluteRegularFile(_ value: String) throws -> URL {
        try absoluteRegularFile(URL(fileURLWithPath: value))
    }

    private static func absoluteRegularFile(_ url: URL) throws -> URL {
        guard url.path.hasPrefix("/"), url.standardizedFileURL.path == url.path else {
            throw ASHP08NativeError.invalidPath(
                "file must be an absolute normalized path: \(url.path)"
            )
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.isAliasFile != true else {
            throw ASHP08NativeError.invalidPath(
                "file is absent, non-regular, symlink, or alias: \(url.path)"
            )
        }
        return url
    }

    private static func bundledResourceRoot() throws -> URL {
        guard let resources = Bundle.main.resourceURL else {
            throw ASHP08NativeError.invalidArtifact("application resource root is absent")
        }
        return try absoluteDirectory(
            resources
                .appendingPathComponent("ASH", isDirectory: true)
                .appendingPathComponent("LockedV3", isDirectory: true)
                .path
        )
    }

    private static func verifyExactReleaseResources(
        bundledRoot: URL,
        externalRoot: URL
    ) throws -> [[String: Any]] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey
        ]
        let bundledEntries = try fileManager.contentsOfDirectory(
            at: bundledRoot,
            includingPropertiesForKeys: keys,
            options: []
        )
        let externalEntries = try fileManager.contentsOfDirectory(
            at: externalRoot,
            includingPropertiesForKeys: keys,
            options: []
        )
        guard bundledEntries.map(\.lastPathComponent).sorted()
                == resourceFilenames.sorted(),
              externalEntries.map(\.lastPathComponent).sorted()
                == resourceFilenames.sorted() else {
            throw ASHP08NativeError.invalidArtifact(
                "bundled and external release roots must each contain exactly the authorized six-file set"
            )
        }
        return try resourceFilenames.map { filename in
            let bundled = try absoluteRegularFile(
                bundledRoot.appendingPathComponent(filename)
            )
            let external = try absoluteRegularFile(
                externalRoot.appendingPathComponent(filename)
            )
            let bundledBytes = try Data(contentsOf: bundled, options: .mappedIfSafe)
            let externalBytes = try Data(contentsOf: external, options: .mappedIfSafe)
            guard bundledBytes == externalBytes else {
                throw ASHP08NativeError.invalidArtifact(
                    "bundled release member differs from external P06 bytes: \(filename)"
                )
            }
            return [
                "filename": filename,
                "sha256": sha256(bundledBytes),
                "size_bytes": bundledBytes.count
            ]
        }
    }

    private static func verifiedCanonicalArtifact(
        at url: URL,
        hashField: String
    ) throws -> [String: Any] {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let document = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let observedHash = document[hashField] as? String else {
            throw ASHP08NativeError.invalidArtifact(
                "\(url.lastPathComponent) is not a hashed JSON object"
            )
        }
        var hashInput = document
        hashInput.removeValue(forKey: hashField)
        let expectedHash = try canonicalSHA256(hashInput)
        guard observedHash == expectedHash else {
            throw ASHP08NativeError.invalidArtifact(
                "\(url.lastPathComponent) self-hash differs"
            )
        }
        var expectedBytes = try canonicalData(document)
        expectedBytes.append(0x0a)
        guard bytes == expectedBytes else {
            throw ASHP08NativeError.invalidArtifact(
                "\(url.lastPathComponent) is not canonical one-LF JSON"
            )
        }
        return document
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func deviceIdentity(_ device: MTLDevice) throws -> [String: Any] {
        [
            "platform": "macOS",
            "hardware_model": try sysctlString("hw.model"),
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "os_build": try sysctlString("kern.osversion"),
            "metal_device_name": device.name,
            "metal_registry_id": String(device.registryID),
            "metal_low_power": device.isLowPower,
            "metal_removable": device.isRemovable,
            "metal_unified_memory": device.hasUnifiedMemory
        ]
    }

    private static func sysctlString(_ name: String) throws -> String {
        var length = 0
        guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 1 else {
            throw ASHP08NativeError.invalidArtifact("sysctl \(name) length failed")
        }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname(name, &bytes, &length, nil, 0) == 0 else {
            throw ASHP08NativeError.invalidArtifact("sysctl \(name) read failed")
        }
        return String(cString: bytes)
    }

    private static func decodeFrames(
        _ url: URL,
        expectedWidth: Int,
        expectedHeight: Int
    ) async throws -> [ASHP08DecodedFrame] {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else {
            throw ASHP08NativeError.invalidFixture("fixture must have exactly one video track")
        }
        let size = try await track.load(.naturalSize)
        guard Int(abs(size.width).rounded()) == expectedWidth,
              Int(abs(size.height).rounded()) == expectedHeight else {
            throw ASHP08NativeError.invalidFixture(
                "decoded track dimensions differ from \(expectedWidth)x\(expectedHeight)"
            )
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ASHP08NativeError.mediaFailure("reader rejected NV12 output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ASHP08NativeError.mediaFailure(
                "reader start failed: \(String(describing: reader.error))"
            )
        }
        var frames: [ASHP08DecodedFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferGetPixelFormatType(pixelBuffer)
                    == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                  CVPixelBufferGetWidth(pixelBuffer) == expectedWidth,
                  CVPixelBufferGetHeight(pixelBuffer) == expectedHeight,
                  try ASHNV12FrameCodec.chromaSiting(for: pixelBuffer) == .left else {
                throw ASHP08NativeError.invalidFixture(
                    "decoded frame violates the 420v NV12 left-sited geometry contract"
                )
            }
            let luma = try activePlaneData(pixelBuffer, plane: 0)
            let cbcr = try activePlaneData(pixelBuffer, plane: 1)
            var nv12 = luma
            nv12.append(cbcr)
            frames.append(ASHP08DecodedFrame(
                ordinal: frames.count,
                presentationTimestamp: CMSampleBufferGetPresentationTimeStamp(sample),
                pixelBuffer: pixelBuffer,
                decodedNV12SHA256: sha256(nv12),
                yPlaneSHA256: sha256(luma),
                cbcrPlaneSHA256: sha256(cbcr)
            ))
        }
        guard reader.status == .completed else {
            throw ASHP08NativeError.mediaFailure(
                "reader did not complete: \(String(describing: reader.error))"
            )
        }
        return frames
    }
}

// swiftlint:enable file_length type_body_length
