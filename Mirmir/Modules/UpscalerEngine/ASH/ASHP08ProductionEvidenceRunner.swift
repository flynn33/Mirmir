import Darwin
import Foundation

@available(macOS 15.4, *)
enum ASHP08ProductionEvidenceRunner {
    enum LaunchDisposition: Equatable {
        case normal
        case requested
        case invalid
    }

    private static let argument = "--mirmir-p08-native-evidence"

    static func launchDisposition() -> LaunchDisposition {
        let hasArgument = ProcessInfo.processInfo.arguments.dropFirst() == [argument]
        let hasEnvironment = ProcessInfo.processInfo.environment["MIRMIR_P08_APP_MODE"]
            .map { !$0.isEmpty } ?? false
        switch (hasArgument, hasEnvironment) {
        case (false, false): return .normal
        case (true, true): return .requested
        default: return .invalid
        }
    }

    static func runAndExit() async -> Never {
        do {
            let mode = try ASHP08NativeSupport.environment("MIRMIR_P08_APP_MODE")
            let context = try await ASHP08NativeSupport.loadContext()
            switch mode {
            case "metal-parity":
                let payload = try await ASHP08DescriptorParityRuntime.measure(
                    context: context
                )
                try writeSlice(
                    name: "metal_parity",
                    payload: payload,
                    context: context
                )
            case "performance":
                let payload = try await ASHP08PerformanceRuntime.measure(context: context)
                try writeSlice(
                    name: "performance",
                    payload: payload,
                    context: context
                )
            case "resource-ring":
                let payload = try await ASHP08PerformanceRuntime.measureResourceRing(
                    context: context
                )
                try writeSlice(
                    name: "resource_ring",
                    payload: payload,
                    context: context
                )
            case "profile-direct-2x":
                try await writeProfile(route: .direct2x, context: context)
            case "profile-direct-3-over-2":
                try await writeProfile(route: .direct3Over2, context: context)
            case "capture-direct-2x":
                try await writeCapture(route: .direct2x, context: context)
            case "capture-direct-3-over-2":
                try await writeCapture(route: .direct3Over2, context: context)
            case "assemble":
                try assemble(context: context)
            default:
                throw ASHP08NativeError.invalidEnvironment("MIRMIR_P08_APP_MODE")
            }
            fflush(stdout)
            fflush(stderr)
            exit(EXIT_SUCCESS)
        } catch {
            fputs("P08 native execution failed: \(error)\n", stderr)
            fflush(stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func writeProfile(
        route: ASHSpatialRouteV2,
        context: ASHP08NativeContext
    ) async throws {
        let payload = try await ASHP08PerformanceRuntime.runProfile(
            route: route,
            context: context
        )
        try writeSlice(
            name: "profile_\(route.rawValue)",
            payload: payload,
            context: context
        )
    }

    private static func writeCapture(
        route: ASHSpatialRouteV2,
        context: ASHP08NativeContext
    ) async throws {
        let outputPath = try ASHP08NativeSupport.environment(
            "MIRMIR_P08_GPU_CAPTURE_OUTPUT"
        )
        let output = URL(fileURLWithPath: outputPath)
        let expectedName = "\(route.rawValue).gputrace"
        guard output.path == outputPath,
              output.lastPathComponent == expectedName else {
            throw ASHP08NativeError.invalidPath(
                "GPU capture output must end in \(expectedName)"
            )
        }
        let payload = try await ASHP08DescriptorParityRuntime.capture(
            route: route,
            context: context,
            outputURL: output
        )
        try writeSlice(
            name: "capture_\(route.rawValue)",
            payload: payload,
            context: context
        )
    }

    private static func writeSlice(
        name: String,
        payload: [String: Any],
        context: ASHP08NativeContext
    ) throws {
        try ASHP08NativeSupport.writeNewDocument([
            "schema_version": "1.0.0",
            "artifact_kind": "p08_native_slice",
            "slice": name,
            "run_id": context.runID,
            "execution_identity": context.executionIdentity,
            "device": context.device,
            "device_identity_sha256": context.deviceIdentitySHA256,
            "payload": payload,
            "hash_scope": ASHP08NativeSupport.hashScope
        ], environmentName: "MIRMIR_P08_SLICE_OUTPUT")
    }

    private static func assemble(context: ASHP08NativeContext) throws {
        let parity = try readSlice(
            environment: "MIRMIR_P08_METAL_PARITY_FRAGMENT",
            expectedName: "metal_parity",
            context: context
        )
        let performance = try readSlice(
            environment: "MIRMIR_P08_PERFORMANCE_FRAGMENT",
            expectedName: "performance",
            context: context
        )
        let resources = try readSlice(
            environment: "MIRMIR_P08_RESOURCE_RING_FRAGMENT",
            expectedName: "resource_ring",
            context: context
        )
        let profile2x = try readSlice(
            environment: "MIRMIR_P08_PROFILE_DIRECT2X_FRAGMENT",
            expectedName: "profile_direct_2x",
            context: context
        )
        let profile3Over2 = try readSlice(
            environment: "MIRMIR_P08_PROFILE_DIRECT3OVER2_FRAGMENT",
            expectedName: "profile_direct_3_over_2",
            context: context
        )
        let capture2x = try readSlice(
            environment: "MIRMIR_P08_CAPTURE_DIRECT2X_FRAGMENT",
            expectedName: "capture_direct_2x",
            context: context
        )
        let capture3Over2 = try readSlice(
            environment: "MIRMIR_P08_CAPTURE_DIRECT3OVER2_FRAGMENT",
            expectedName: "capture_direct_3_over_2",
            context: context
        )
        let xctraceVersion = try ASHP08NativeSupport.environment(
            "MIRMIR_P08_XCTRACE_VERSION"
        )
        guard !xctraceVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASHP08NativeError.invalidEnvironment("MIRMIR_P08_XCTRACE_VERSION")
        }
        let profiles = ["time_profiler", "allocations", "metal_system_trace"]
            .flatMap { tool in
                ASHSpatialRouteV2.allCases.map { route in
                    [
                        "tool": tool,
                        "route": route.rawValue,
                        "archive_name": "\(tool)-\(route.rawValue).trace"
                    ]
                }
            }
        let document: [String: Any] = [
            "schema_version": "1.0.0",
            "artifact_kind": "p08_native_measurements",
            "run_id": context.runID,
            "execution_identity": context.executionIdentity,
            "device": context.device,
            "device_identity_sha256": context.deviceIdentitySHA256,
            "xctest_result_bundles": [
                "metal_parity": "metal-parity.xcresult",
                "performance": "performance.xcresult",
                "resource_ring": "resource-ring.xcresult"
            ],
            "metal_parity": parity,
            "performance": performance,
            "resource_ring": resources,
            "instruments": [
                "xctrace_version": xctraceVersion,
                "profiles": profiles,
                "route_observations": [profile2x, profile3Over2]
            ],
            "gpu_capture": [
                "capture_tool": [
                    "name": "MTLCaptureManager",
                    "version": ProcessInfo.processInfo.operatingSystemVersionString
                ],
                "captures": [capture2x, capture3Over2]
            ],
            "hash_scope": ASHP08NativeSupport.hashScope
        ]
        try ASHP08NativeSupport.writeNewDocument(
            document,
            environmentName: "MIRMIR_P08_NATIVE_MEASUREMENTS_OUTPUT"
        )
    }

    private static func readSlice(
        environment: String,
        expectedName: String,
        context: ASHP08NativeContext
    ) throws -> [String: Any] {
        let document = try ASHP08NativeSupport.readFinalizedDocument(
            environmentName: environment
        )
        guard let sliceExecutionIdentity = document["execution_identity"]
                as? [String: Any],
              let sliceDevice = document["device"] as? [String: Any] else {
            throw ASHP08NativeError.invalidArtifact(
                "native slice identity is absent: \(expectedName)"
            )
        }
        guard document["schema_version"] as? String == "1.0.0",
              document["artifact_kind"] as? String == "p08_native_slice",
              document["slice"] as? String == expectedName,
              document["run_id"] as? String == context.runID,
              try ASHP08NativeSupport.canonicalSHA256(
                sliceExecutionIdentity
              ) == ASHP08NativeSupport.canonicalSHA256(context.executionIdentity),
              try ASHP08NativeSupport.canonicalSHA256(sliceDevice)
                == context.deviceIdentitySHA256,
              document["device_identity_sha256"] as? String
                == context.deviceIdentitySHA256,
              document["hash_scope"] as? String == ASHP08NativeSupport.hashScope,
              let payload = document["payload"] as? [String: Any] else {
            throw ASHP08NativeError.invalidArtifact(
                "native slice identity or payload differs: \(expectedName)"
            )
        }
        return payload
    }
}
