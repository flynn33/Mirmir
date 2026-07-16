import Foundation

enum ASHLockedArtifactStoreErrorV3: Error, Equatable, Sendable {
    case invalidResourceRoot
    case resourceSetMismatch(expected: [String], observed: [String])
    case invalidResource(String)
    case routeArtifactMismatch(ASHSpatialRouteV2)
}

struct ASHLockedArtifactStoreDiagnosticsV3: Equatable, Sendable {
    let loadAttemptCount: Int
    let publicationCount: Int
}

struct ASHLockedArtifactSetV3: Equatable, Sendable {
    let configurationBytes: Data
    let mappingBytes: Data
    let manifestBytes: Data
    let nativeParityManifestBytes: Data
    let configuration: ASHLUTLockedConfigurationV3
    let mapping: ASHLockedVideoMappingV2
    let manifest: ASHLockedReleaseLUTManifestV3
    let direct2xLUT: ASHLUTLoadedV3
    let direct3Over2LUT: ASHLUTLoadedV3

    func lut(for route: ASHSpatialRouteV2) -> ASHLUTLoadedV3 {
        switch route {
        case .direct2x: direct2xLUT
        case .direct3Over2: direct3Over2LUT
        }
    }
}

actor ASHLockedArtifactStoreV3 {
    static let expectedFilenames = [
        ASHLockedReleaseLUTManifestV3.filename,
        ASHLockedReleaseLUTManifestV3.compilerInputFilename,
        "locked-mapping.json",
        "direct2x.ashlut",
        "direct3over2.ashlut",
        ASHLockedReleaseLUTManifestV3.nativeParityManifestFilename
    ].sorted()

    private let resourceRoot: URL
    private var cached: ASHLockedArtifactSetV3?
    private var loadAttemptCount = 0
    private var publicationCount = 0

    init(resourceRoot: URL) {
        self.resourceRoot = resourceRoot
    }

    func artifacts() throws -> ASHLockedArtifactSetV3 {
        if let cached { return cached }
        loadAttemptCount += 1
        let loaded = try Self.loadAtomically(from: resourceRoot)
        cached = loaded
        publicationCount += 1
        return loaded
    }

    func diagnostics() -> ASHLockedArtifactStoreDiagnosticsV3 {
        ASHLockedArtifactStoreDiagnosticsV3(
            loadAttemptCount: loadAttemptCount,
            publicationCount: publicationCount
        )
    }

    private static func loadAtomically(from root: URL) throws -> ASHLockedArtifactSetV3 {
        let values = try? root.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey
        ])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw ASHLockedArtifactStoreErrorV3.invalidResourceRoot
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        let filenames = contents.map(\.lastPathComponent).sorted()
        guard filenames == expectedFilenames else {
            throw ASHLockedArtifactStoreErrorV3.resourceSetMismatch(
                expected: expectedFilenames,
                observed: filenames
            )
        }

        let manifestBytes = try readRegularFile(
            root.appendingPathComponent(ASHLockedReleaseLUTManifestV3.filename)
        )
        let configurationBytes = try readRegularFile(
            root.appendingPathComponent(ASHLockedReleaseLUTManifestV3.compilerInputFilename)
        )
        let mappingBytes = try readRegularFile(
            root.appendingPathComponent("locked-mapping.json")
        )
        let nativeParityManifestBytes = try readRegularFile(
            root.appendingPathComponent(
                ASHLockedReleaseLUTManifestV3.nativeParityManifestFilename
            )
        )
        let configuration = try ASHLUTLockedConfigurationJSONLoaderV3.load(configurationBytes)
        let mapping = try ASHLockedVideoMappingV2.load(
            mappingBytes,
            expectedSHA256: ASHLUTHashV2(hex: configuration.mappingSHA256.hex)
        )
        try mapping.validate(configuration: configuration)
        let manifest = try ASHLockedReleaseLUTManifestV3.load(
            manifestBytes,
            compilerInputData: configurationBytes,
            nativeParityManifestData: nativeParityManifestBytes,
            configuration: configuration
        )
        let direct2x = try loadRoute(
            .direct2x,
            root: root,
            manifest: manifest,
            configuration: configuration
        )
        let direct3Over2 = try loadRoute(
            .direct3Over2,
            root: root,
            manifest: manifest,
            configuration: configuration
        )
        return ASHLockedArtifactSetV3(
            configurationBytes: configurationBytes,
            mappingBytes: mappingBytes,
            manifestBytes: manifestBytes,
            nativeParityManifestBytes: nativeParityManifestBytes,
            configuration: configuration,
            mapping: mapping,
            manifest: manifest,
            direct2xLUT: direct2x,
            direct3Over2LUT: direct3Over2
        )
    }

    private static func loadRoute(
        _ route: ASHSpatialRouteV2,
        root: URL,
        manifest: ASHLockedReleaseLUTManifestV3,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> ASHLUTLoadedV3 {
        let binding = try manifest.route(route)
        let data = try readRegularFile(root.appendingPathComponent(binding.path))
        let wholeFileSHA256 = ASHLUTBinaryCodecV3.validationSHA256(data)
        guard data.count == binding.wholeFileSizeBytes,
              wholeFileSHA256 == binding.wholeFileSHA256 else {
            throw ASHLockedLUTManifestErrorV3.wholeFileHashMismatch
        }
        guard data.count >= ASHLUTBinaryContractV3.headerSize,
              ASHLUTLittleEndianV3.uint32(data, at: 288) == binding.headerCRC32,
              ASHLUTLittleEndianV3.uint32(data, at: 292) == binding.payloadCRC32 else {
            throw ASHLockedLUTManifestErrorV3.checksumMismatch
        }
        let loaded = try ASHLUTBinaryCodecV3.load(
            data,
            expectedRoute: route,
            configuration: configuration
        )
        guard loaded.payloadSHA256 == binding.payloadSHA256 else {
            throw ASHLockedLUTManifestErrorV3.payloadHashMismatch
        }
        guard loaded.wholeFileSHA256 == binding.wholeFileSHA256,
              loaded.entries.count == binding.entryCount,
              loaded.parameters.count == binding.parameterCount else {
            throw ASHLockedArtifactStoreErrorV3.routeArtifactMismatch(route)
        }
        return loaded
    }

    private static func readRegularFile(_ url: URL) throws -> Data {
        let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey
        ])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            throw ASHLockedArtifactStoreErrorV3.invalidResource(url.lastPathComponent)
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
