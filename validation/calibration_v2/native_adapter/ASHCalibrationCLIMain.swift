import Darwin
import Foundation

private func waitForMirmirExecutionGate() throws {
    guard let raw = ProcessInfo.processInfo.environment["MIRMIR_EXECUTION_GATE_FD"] else {
        return
    }
    guard let descriptor = Int32(raw), descriptor >= 0 else {
        throw ASHCalibrationCLIError.invalidArguments
    }
    var authorization: UInt8 = 0
    var count = -1
    repeat {
        count = withUnsafeMutableBytes(of: &authorization) { bytes in
            Darwin.read(descriptor, bytes.baseAddress, 1)
        }
    } while count < 0 && errno == EINTR
    Darwin.close(descriptor)
    guard count == 1, authorization == 0xA5 else {
        throw ASHCalibrationCLIError.invalidArguments
    }
}

@main
struct ASHCalibrationCLIMain {
    static func main() {
        do {
            try waitForMirmirExecutionGate()
            _ = Darwin.umask(0o077)
            guard CommandLine.arguments.count >= 2 else {
                throw ASHCalibrationCLIError.invalidArguments
            }
            switch CommandLine.arguments[1] {
            case "compile-candidate":
                try compileCandidate(CommandLine.arguments.dropFirst(2))
            case "serve-candidate":
                try serveCandidate(CommandLine.arguments.dropFirst(2))
            default:
                throw ASHCalibrationCLIError.invalidArguments
            }
        } catch {
            let message = "ASH calibration CLI failure: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(1)
        }
    }

    private static func compileCandidate(_ arguments: ArraySlice<String>) throws {
        let values = try ASHCalibrationCLIOptions(arguments).require([
            "--compiler-input", "--mapping", "--operator-bank", "--output-directory"
        ])
        let compilerInputData = try ASHCalibrationCLIFileIO.readRegularFile(
            values["--compiler-input"]!
        )
        switch try compilerInputSchemaVersion(compilerInputData) {
        case "1.0.0":
            try compileCandidateV1(
                values,
                compilerInputData: compilerInputData
            )
        case "2.0.0":
            try compileCandidateV2(
                values,
                compilerInputData: compilerInputData
            )
        default:
            throw ASHCalibrationCLIError.unsupported("compiler-input schema version")
        }
    }

    private static func compileCandidateV1(
        _ values: [String: String],
        compilerInputData: Data
    ) throws {
        let inputs = try loadConfigurationInputsV1(
            values,
            compilerInputData: compilerInputData
        )
        let outputDirectory = values["--output-directory"]!
        try ASHCalibrationCLIFileIO.validateDirectory(outputDirectory)
        var rows: [[String: Any]] = []
        for route in ASHSpatialRouteV2.allCases {
            let compilation = try ASHLUTLeafCompilerV2.compile(
                route: route,
                configuration: inputs.configuration
            )
            let artifact = try ASHLUTBinaryCodecV2.serialize(compilation)
            let filename = route == .direct2x ? "direct2x.ashlut" : "direct3over2.ashlut"
            let path = (outputDirectory as NSString).appendingPathComponent(filename)
            try ASHCalibrationCLIFileIO.writeNewRegularFile(artifact.data, path: path)
            let reopened = try ASHCalibrationCLIFileIO.readRegularFile(path)
            let loaded = try ASHLUTBinaryCodecV2.load(
                reopened,
                expectedRoute: route,
                configuration: inputs.configuration
            )
            rows.append(routeRow(loaded, path: filename))
        }
        try ASHCalibrationCLIJSON.writeLine([
            "schema_version": "1.0.0",
            "status": "compiled",
            "configuration_id": inputs.configuration.configurationID,
            "compiler_inputs_sha256": inputs.configuration.compilerInputsSHA256.hex,
            "mapping_sha256": inputs.mapping.sha256.hex,
            "operator_bank_sha256": inputs.operatorBank.sha256.hex,
            "routes": rows,
            "offline_compile_invocation_count": 1,
            "runtime_load_count": 0,
            "native_parity_claimed": false
        ])
    }

    private static func compileCandidateV2(
        _ values: [String: String],
        compilerInputData: Data
    ) throws {
        let inputs = try loadConfigurationInputsV2(
            values,
            compilerInputData: compilerInputData
        )
        let outputDirectory = values["--output-directory"]!
        try ASHCalibrationCLIFileIO.validateDirectory(outputDirectory)
        var rows: [[String: Any]] = []
        for route in ASHSpatialRouteV2.allCases {
            let compilation = try ASHLUTLeafCompilerV3.compile(
                route: route,
                configuration: inputs.configuration
            )
            let artifact = try ASHLUTBinaryCodecV3.serialize(compilation)
            let filename = route == .direct2x ? "direct2x.ashlut" : "direct3over2.ashlut"
            let path = (outputDirectory as NSString).appendingPathComponent(filename)
            try ASHCalibrationCLIFileIO.writeNewRegularFile(artifact.data, path: path)
            let reopened = try ASHCalibrationCLIFileIO.readRegularFile(path)
            let loaded = try ASHLUTBinaryCodecV3.load(
                reopened,
                expectedRoute: route,
                configuration: inputs.configuration
            )
            rows.append(routeRowV3(loaded, path: filename))
        }
        try ASHCalibrationCLIJSON.writeLine([
            "schema_version": "2.0.0",
            "status": "compiled",
            "configuration_id": inputs.configuration.configurationID,
            "compiler_inputs_sha256": inputs.configuration.compilerInputsSHA256.hex,
            "mapping_sha256": inputs.configuration.mappingSHA256.hex,
            "operator_bank_sha256": inputs.configuration.operatorBankSHA256.hex,
            "routes": rows,
            "offline_compile_invocation_count": 1,
            "runtime_load_count": 0,
            "native_parity_claimed": false
        ])
    }

    private static func serveCandidate(_ arguments: ArraySlice<String>) throws {
        let values = try ASHCalibrationCLIOptions(arguments).require([
            "--compiler-input", "--mapping", "--operator-bank", "--runtime-manifest",
            "--direct2x-lut", "--direct3over2-lut", "--source-manifest"
        ])
        let compilerInputData = try ASHCalibrationCLIFileIO.readRegularFile(
            values["--compiler-input"]!
        )
        switch try compilerInputSchemaVersion(compilerInputData) {
        case "1.0.0":
            break
        case "2.0.0":
            try serveCandidateV2(values, compilerInputData: compilerInputData)
            return
        default:
            throw ASHCalibrationCLIError.unsupported(
                "candidate runtime compiler-input schema"
            )
        }
        let inputs = try loadConfigurationInputsV1(
            values,
            compilerInputData: compilerInputData
        )
        let manifestData = try ASHCalibrationCLIFileIO.readRegularFile(
            values["--runtime-manifest"]!
        )
        let manifest = try ASHLockedCandidateLUTManifestV1.load(
            manifestData,
            compilerInputData: inputs.compilerInputData,
            configuration: inputs.configuration
        )
        let executableData = try ASHCalibrationCLIFileIO.readRegularFile(
            CommandLine.arguments[0]
        )
        guard ASHCalibrationCLIHash.value(executableData) == manifest.executableSHA256 else {
            throw ASHCalibrationCLIError.hashMismatch("native executable")
        }
        let sourceManifestData = try ASHCalibrationCLIFileIO.readRegularFile(
            values["--source-manifest"]!
        )
        guard ASHCalibrationCLIHash.value(sourceManifestData)
                == manifest.sourceManifestSHA256 else {
            throw ASHCalibrationCLIError.hashMismatch("source manifest")
        }
        let direct2xData = try ASHCalibrationCLIFileIO.readRegularFile(
            values["--direct2x-lut"]!
        )
        let direct3Over2Data = try ASHCalibrationCLIFileIO.readRegularFile(
            values["--direct3over2-lut"]!
        )
        let session = try ASHCalibrationNativeSession(
            configuration: inputs.configuration,
            mapping: inputs.mapping,
            operatorBank: inputs.operatorBank,
            manifest: manifest,
            direct2xData: direct2xData,
            direct3Over2Data: direct3Over2Data
        )
        try ASHCalibrationCLIJSON.writeLine([
            "schema_version": "1.0.0",
            "status": "ready",
            "configuration_id": inputs.configuration.configurationID,
            "candidate_lut_runtime_manifest_sha256": manifest.manifestSHA256.hex,
            "session_loaded_lut_instance_count": 2,
            "per_frame_lut_load_count": 0,
            "native_parity_claimed": false
        ])
        while let line = readLine(strippingNewline: true) {
            let data = Data(line.utf8)
            let requestSHA256 = ASHCalibrationCLIHash.hex(data)
            do {
                switch try ASHCalibrationRequestOperation.parse(data) {
                case "process_batch":
                    let request = try ASHCalibrationBatchRequest.parse(
                        data,
                        configuration: inputs.configuration
                    )
                    let frames = try session.process(request)
                    try ASHCalibrationCLIJSON.writeLine([
                        "schema_version": "1.0.0",
                        "status": "ok",
                        "request_sha256": requestSHA256,
                        "frames": frames
                    ])
                case "measure_dispatch_projection":
                    let request = try ASHCalibrationMeasurementRequest.parse(
                        data,
                        configuration: inputs.configuration
                    )
                    let measurement = try session.measure(request)
                    try ASHCalibrationCLIJSON.writeLine([
                        "schema_version": "1.0.0",
                        "status": "ok",
                        "request_sha256": requestSHA256,
                        "measurement": measurement
                    ])
                case "reconstruct_control":
                    let request = try ASHCalibrationControlRequest.parse(
                        data,
                        configuration: inputs.configuration,
                        mapping: inputs.mapping
                    )
                    let control = try session.control(request)
                    try ASHCalibrationCLIJSON.writeLine([
                        "schema_version": "1.0.0",
                        "status": "ok",
                        "request_sha256": requestSHA256,
                        "control": control
                    ])
                case "prepare_non_ash_cache":
                    let request = try ASHCalibrationNonASHCachePrepareRequest.parse(
                        data,
                        configuration: inputs.configuration,
                        mapping: inputs.mapping
                    )
                    let cache = try session.prepareNonASHCache(request)
                    try ASHCalibrationCLIJSON.writeLine([
                        "schema_version": "1.0.0",
                        "status": "ok",
                        "request_sha256": requestSHA256,
                        "cache": cache
                    ])
                case "import_non_ash_cache":
                    let request = try ASHCalibrationNonASHCacheImportRequest.parse(
                        data,
                        configuration: inputs.configuration,
                        mapping: inputs.mapping
                    )
                    let cache = try session.importNonASHCache(request)
                    try ASHCalibrationCLIJSON.writeLine([
                        "schema_version": "1.0.0",
                        "status": "ok",
                        "request_sha256": requestSHA256,
                        "cache": cache
                    ])
                case "reconstruct_non_ash_cached":
                    let request = try ASHCalibrationNonASHCachedReconstructionRequest.parse(
                        data
                    )
                    let reconstruction = try session.reconstructNonASHCached(request)
                    try ASHCalibrationCLIJSON.writeLine([
                        "schema_version": "1.0.0",
                        "status": "ok",
                        "request_sha256": requestSHA256,
                        "cached_reconstruction": reconstruction
                    ])
                case "reconstruct_fixed_cached":
                    let request = try ASHCalibrationFixedCachedReconstructionRequest.parse(
                        data
                    )
                    let reconstruction = try session.reconstructFixedCached(request)
                    try ASHCalibrationCLIJSON.writeLine([
                        "schema_version": "1.0.0",
                        "status": "ok",
                        "request_sha256": requestSHA256,
                        "cached_reconstruction": reconstruction
                    ])
                case "diagnose_corrective_frame":
                    let request = try ASHCalibrationCorrectiveDiagnosticRequest.parse(
                        data,
                        configuration: inputs.configuration
                    )
                    let diagnostic = try session.diagnoseCorrective(request)
                    try ASHCalibrationCLIJSON.writeLine([
                        "schema_version": "1.0.0",
                        "status": "ok",
                        "request_sha256": requestSHA256,
                        "corrective_diagnostic": diagnostic
                    ])
                default:
                    throw ASHCalibrationCLIError.unsupported("operation")
                }
            } catch {
                try ASHCalibrationCLIJSON.writeLine([
                    "schema_version": "1.0.0",
                    "status": "error",
                    "request_sha256": requestSHA256,
                    "error_type": String(describing: type(of: error)),
                    "message": String(describing: error)
                ])
            }
        }
    }

    private static func serveCandidateV2(
        _ values: [String: String],
        compilerInputData: Data
    ) throws {
        let inputs = try loadConfigurationInputsV2(
            values,
            compilerInputData: compilerInputData
        )
        let mapping = try ASHLockedVideoMappingV2.loadCalibrationCandidateV2(
            inputs.mappingData,
            expectedSHA256: inputs.configuration.mappingSHA256,
            configuration: inputs.configuration
        )
        let manifestData = try ASHCalibrationCLIFileIO.readRegularFile(
            values["--runtime-manifest"]!
        )
        let manifest = try ASHLockedCandidateLUTManifestV2.load(
            manifestData,
            compilerInputData: inputs.compilerInputData,
            configuration: inputs.configuration
        )
        let executableData = try ASHCalibrationCLIFileIO.readRegularFile(
            CommandLine.arguments[0]
        )
        guard ASHCalibrationCLIHash.hex(executableData)
                == manifest.executableSHA256.hex else {
            throw ASHCalibrationCLIError.hashMismatch("native executable")
        }
        let sourceManifestData = try ASHCalibrationCLIFileIO.readRegularFile(
            values["--source-manifest"]!
        )
        guard ASHCalibrationCLIHash.hex(sourceManifestData)
                == manifest.sourceManifestSHA256.hex else {
            throw ASHCalibrationCLIError.hashMismatch("source manifest")
        }
        let session = try ASHCalibrationNativeSessionV2(
            configuration: inputs.configuration,
            mapping: mapping,
            manifest: manifest,
            direct2xData: ASHCalibrationCLIFileIO.readRegularFile(
                values["--direct2x-lut"]!
            ),
            direct3Over2Data: ASHCalibrationCLIFileIO.readRegularFile(
                values["--direct3over2-lut"]!
            )
        )
        try ASHCalibrationCLIJSON.writeLine([
            "schema_version": "2.0.0",
            "status": "ready",
            "configuration_id": inputs.configuration.configurationID,
            "candidate_lut_runtime_manifest_sha256": manifest.manifestSHA256.hex,
            "session_loaded_lut_instance_count": 2,
            "per_frame_lut_load_count": 0,
            "native_parity_claimed": false
        ])
        while let line = readLine(strippingNewline: true) {
            let data = Data(line.utf8)
            let requestSHA256 = ASHCalibrationCLIHash.hex(data)
            do {
                switch try ASHCalibrationRequestOperation.parse(data) {
                case "process_batch":
                    let request = try ASHCalibrationBatchRequest.parse(
                        data,
                        configuration: inputs.configuration
                    )
                    let frames = try session.process(request)
                    try ASHCalibrationCLIJSON.writeLine([
                        "schema_version": "2.0.0",
                        "status": "ok",
                        "request_sha256": requestSHA256,
                        "frames": frames
                    ])
                case "reconstruct_control":
                    let request = try ASHCalibrationControlRequest.parse(
                        data,
                        configuration: inputs.configuration,
                        mapping: mapping
                    )
                    let control = try session.control(request)
                    try ASHCalibrationCLIJSON.writeLine([
                        "schema_version": "2.0.0",
                        "status": "ok",
                        "request_sha256": requestSHA256,
                        "control": control
                    ])
                default:
                    throw ASHCalibrationCLIError.unsupported(
                        "format-1.2 candidate operation"
                    )
                }
            } catch {
                try ASHCalibrationCLIJSON.writeLine([
                    "schema_version": "2.0.0",
                    "status": "error",
                    "request_sha256": requestSHA256,
                    "error_type": String(describing: type(of: error)),
                    "message": String(describing: error)
                ])
            }
        }
    }

    private struct ConfigurationInputsV1 {
        let compilerInputData: Data
        let configuration: ASHLUTLockedConfigurationV2
        let mapping: ASHLockedVideoMappingV2
        let operatorBank: ASHLockedOperatorBankV2
    }

    private struct ConfigurationInputsV2 {
        let compilerInputData: Data
        let configuration: ASHLUTLockedConfigurationV3
        let mappingData: Data
        let operatorBankData: Data
    }

    private static func compilerInputSchemaVersion(_ data: Data) throws -> String {
        var parser = ASHLUTStrictJSONParserV2(data: data)
        let value = try parser.parse()
        guard case .object(let root) = value,
              case .string(let schemaVersion)? = root["schema_version"] else {
            throw ASHCalibrationCLIError.invalidRequest(
                "compiler-input schema discriminator is absent"
            )
        }
        let canonical = ASHLUTCanonicalJSONV2.encode(value)
        switch schemaVersion {
        case "1.0.0":
            guard data == canonical else {
                throw ASHCalibrationCLIError.invalidRequest(
                    "schema-1 compiler input is not canonical"
                )
            }
        case "2.0.0":
            var canonicalFile = canonical
            canonicalFile.append(0x0a)
            guard data == canonicalFile else {
                throw ASHCalibrationCLIError.invalidRequest(
                    "schema-2 compiler input is not canonical LF-terminated JSON"
                )
            }
        default:
            break
        }
        return schemaVersion
    }

    private static func loadConfigurationInputsV1(
        _ values: [String: String],
        compilerInputData: Data
    ) throws -> ConfigurationInputsV1 {
        let configuration = try ASHLUTLockedConfigurationJSONLoaderV2.load(
            compilerInputData
        )
        let mappingData = try ASHCalibrationCLIFileIO.readRegularFile(values["--mapping"]!)
        let mapping = try ASHLockedVideoMappingV2.load(
            mappingData,
            expectedSHA256: configuration.mappingSHA256
        )
        try mapping.validate(configuration: configuration)
        let operatorData = try ASHCalibrationCLIFileIO.readRegularFile(
            values["--operator-bank"]!
        )
        let operatorBank = try ASHLockedOperatorBankV2.load(
            operatorData,
            expectedSHA256: configuration.operatorBankSHA256,
            configuration: configuration
        )
        try operatorBank.validate(mapping: mapping)
        return ConfigurationInputsV1(
            compilerInputData: compilerInputData,
            configuration: configuration,
            mapping: mapping,
            operatorBank: operatorBank
        )
    }

    private static func loadConfigurationInputsV2(
        _ values: [String: String],
        compilerInputData: Data
    ) throws -> ConfigurationInputsV2 {
        let configuration = try ASHLUTLockedConfigurationJSONLoaderV3.load(
            compilerInputData
        )
        let mappingData = try ASHCalibrationCLIFileIO.readRegularFile(
            values["--mapping"]!
        )
        guard ASHCalibrationCLIHash.hex(mappingData)
                == configuration.mappingSHA256.hex else {
            throw ASHCalibrationCLIError.hashMismatch("schema-2 video mapping")
        }
        let operatorBankData = try ASHCalibrationCLIFileIO.readRegularFile(
            values["--operator-bank"]!
        )
        guard ASHCalibrationCLIHash.hex(operatorBankData)
                == configuration.operatorBankSHA256.hex else {
            throw ASHCalibrationCLIError.hashMismatch("schema-2 operator bank")
        }
        return ConfigurationInputsV2(
            compilerInputData: compilerInputData,
            configuration: configuration,
            mappingData: mappingData,
            operatorBankData: operatorBankData
        )
    }

    private static func routeRow(
        _ loaded: ASHLUTLoadedV2,
        path: String
    ) -> [String: Any] {
        let route = loaded.route
        let selection = loaded.configuration.routeSelection(for: route)
        return [
            "route": route.rawValue,
            "route_id": route == .direct2x ? 1 : 2,
            "scale_numerator": route.scaleNumerator,
            "scale_denominator": route.scaleDenominator,
            "phase_count": route.phasePairCount,
            "context_count": 4,
            "valid_state_count": 256,
            "luma_coordinate_policy": selection.lumaCoordinatePolicy.rawValue,
            "chroma_coordinate_policy": selection.chromaCoordinatePolicy.rawValue,
            "analysis_grid_source_step": Int(selection.analysisGridSourceStep),
            "entry_count": loaded.entries.count,
            "parameter_count": loaded.parameters.count,
            "path": path,
            "whole_file_size_bytes": loaded.immutableBytes.count,
            "whole_file_sha256": loaded.wholeFileSHA256.hex,
            "payload_sha256": loaded.payloadSHA256.hex,
            "header_crc32": String(
                format: "0x%08X",
                ASHLUTLittleEndianV2.uint32(loaded.immutableBytes, at: 288)
            ),
            "payload_crc32": String(
                format: "0x%08X",
                ASHLUTLittleEndianV2.uint32(loaded.immutableBytes, at: 292)
            )
        ]
    }

    private static func routeRowV3(
        _ loaded: ASHLUTLoadedV3,
        path: String
    ) -> [String: Any] {
        let route = loaded.route
        let selection = loaded.configuration.routeSelection(for: route)
        return [
            "route": route.rawValue,
            "route_id": route == .direct2x ? 1 : 2,
            "scale_numerator": route.scaleNumerator,
            "scale_denominator": route.scaleDenominator,
            "phase_count": route.phasePairCount,
            "context_count": 4,
            "valid_state_count": 256,
            "plane_count": 2,
            "luma_coordinate_policy": selection.lumaCoordinatePolicy.rawValue,
            "chroma_coordinate_policy": selection.chromaCoordinatePolicy.rawValue,
            "analysis_grid_source_step": Int(selection.analysisGridSourceStep),
            "entry_count": loaded.entries.count,
            "parameter_count": loaded.parameters.count,
            "path": path,
            "whole_file_size_bytes": loaded.immutableBytes.count,
            "whole_file_sha256": loaded.wholeFileSHA256.hex,
            "payload_sha256": loaded.payloadSHA256.hex,
            "header_crc32": String(
                format: "0x%08X",
                ASHLUTLittleEndianV3.uint32(loaded.immutableBytes, at: 288)
            ),
            "payload_crc32": String(
                format: "0x%08X",
                ASHLUTLittleEndianV3.uint32(loaded.immutableBytes, at: 292)
            )
        ]
    }
}
