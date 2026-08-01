import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import Mirmir

final class OutputMediaStructuralCarrierVerificationTests: XCTestCase {
    private let resolution = VideoResolution(width: 64, height: 64)
    private let duration = CMTime(value: 1, timescale: 30)

    func testExplicitStructuralCarrierExpectationAcceptsStrictEmptyShell()
        async throws {
        let timedMetadata = [
            "com.mirmir.release.backend-id": "current-release"
        ]
        let fixture = try await makeFixture(
            shape: .strictShell,
            timedMetadata: timedMetadata
        )
        defer { fixture.remove() }
        let expectation = try await makeExpectation(
            url: fixture.destination,
            roles: [.mirmirStructuralCarrier],
            timedMetadata: timedMetadata
        )

        let result = try await OutputMediaVerifier().verify(
            url: fixture.destination,
            expectation: expectation
        )

        XCTAssertEqual(result.frameCount, 1)
        XCTAssertEqual(result.resolution, resolution)
    }

    func testOrdinaryExpectationDoesNotAuthorizeStructuralCarrier()
        async throws {
        try await assertRejected(
            shape: .strictShell,
            roles: [.ordinary],
            reasonContains: "expected 0, observed 1"
        )
    }

    func testStructuralCarrierExpectationEnforcesExactTrackCount()
        async throws {
        try await assertRejected(
            shape: .strictShell,
            roles: [
                .mirmirStructuralCarrier,
                .mirmirStructuralCarrier
            ],
            reasonContains: "expected 2, observed 1"
        )
    }

    func testStructuralCarrierRejectsMixedFormatIdentifiers()
        async throws {
        try await assertRejected(
            shape: .mixedFormat,
            roles: [.mirmirStructuralCarrier],
            reasonContains: "complete sole format identifier"
        )
    }

    func testStructuralCarrierRejectsRawDataSchema() async throws {
        try await assertRejected(
            shape: .rawDataCarrier,
            roles: [.mirmirStructuralCarrier],
            reasonContains: "canonical carrier schema"
        )
    }

    func testStructuralCarrierRejectsLanguageTaggedSchema() async throws {
        try await assertRejected(
            shape: .languageCarrier,
            roles: [.mirmirStructuralCarrier],
            reasonContains: "canonical carrier schema"
        )
    }

    func testStructuralCarrierRejectsSetupDataSchema() async throws {
        try await assertRejected(
            shape: .setupDataCarrier,
            roles: [.mirmirStructuralCarrier],
            reasonContains: "canonical carrier schema"
        )
    }

    func testStructuralCarrierRejectsChangedLocalIDSchema() async throws {
        try await assertRejected(
            shape: .changedLocalIDCarrier,
            roles: [.mirmirStructuralCarrier],
            reasonContains: "canonical carrier schema"
        )
    }

    func testStructuralCarrierRejectsDecodedCarrierItem()
        async throws {
        try await assertRejected(
            shape: .timedCarrierItem,
            roles: [.mirmirStructuralCarrier],
            reasonContains: "appears as a decoded metadata item"
        )
    }

    func testStructuralCarrierRejectsStaticCarrierItem()
        async throws {
        try await assertRejected(
            shape: .staticCarrierItem,
            roles: [.mirmirStructuralCarrier],
            reasonContains: "static metadata contains the reserved"
        )
    }

    func testStructuralCarrierRejectsMultipleDecodedGroups()
        async throws {
        try await assertRejected(
            shape: .multipleEmptyGroups,
            roles: [.mirmirStructuralCarrier],
            reasonContains: "exactly one decoded group"
        )
    }

    func testPreservationRolesCannotSwapCarrierAndOrdinaryOrdinals()
        async throws {
        let fixture = try await makeCarrierAndForeignFixture()
        defer { fixture.remove() }
        let asset = AVURLAsset(
            url: fixture.destination,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let metadataTracks = try await asset.loadTracks(
            withMediaType: .metadata
        )
        XCTAssertEqual(metadataTracks.count, 2)
        var swappedExpectations:
            [OutputMediaTrackPreservationExpectation] = []
        for (ordinal, track) in metadataTracks.enumerated() {
            let identifiers = try await metadataFormatIdentifiers(track)
            let swappedRole: OutputMediaTrackPreservationRole =
                identifiers.contains(
                    MirmirTimedMetadataMigration.shellCarrierIdentifier
                ) ? .ordinary : .mirmirStructuralCarrier
            swappedExpectations.append(
                try await makeTrackExpectation(
                    asset: asset,
                    track: track,
                    ordinal: ordinal,
                    role: swappedRole
                )
            )
        }
        let expectation = try await makeOutputExpectation(
            asset: asset,
            trackExpectations: swappedExpectations,
            metadataTrackCount: 2
        )

        do {
            _ = try await OutputMediaVerifier().verify(
                url: fixture.destination,
                expectation: expectation
            )
            XCTFail("Expected swapped preservation-role rejection.")
        } catch let error as OutputMediaVerificationError {
            guard case .mediaPreservationMismatch(let reason) = error else {
                return XCTFail("Unexpected verification error: \(error)")
            }
            XCTAssertTrue(reason.contains("structural-carrier"))
            XCTAssertTrue(reason.contains("role"))
        }
    }

    func testPreservationVerifierRejectsSwappedMetadataSampleBindings()
        async throws {
        let fixture = try await makeHeterogeneousForeignFixture()
        defer { fixture.remove() }
        let asset = AVURLAsset(
            url: fixture.destination,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let metadataTracks = try await asset.loadTracks(
            withMediaType: .metadata
        )
        XCTAssertEqual(metadataTracks.count, 1)
        let metadataTrack = try XCTUnwrap(metadataTracks.first)
        let actualExpectation = try await makeTrackExpectation(
            asset: asset,
            track: metadataTrack,
            ordinal: 0,
            role: .ordinary
        )
        let actualBindings = try XCTUnwrap(
            actualExpectation.metadataSampleFormatBindings
        )
        XCTAssertEqual(
            actualBindings.canonicalFormatDescriptionsBySample.count,
            2
        )
        XCTAssertNotEqual(
            actualBindings.canonicalFormatDescriptionsBySample[0],
            actualBindings.canonicalFormatDescriptionsBySample[1]
        )
        let swappedBindings =
            OutputMediaMetadataSampleFormatBindingIdentity(
                canonicalFormatDescriptionsBySample:
                    Array(
                        actualBindings
                            .canonicalFormatDescriptionsBySample.reversed()
                    )
            )
        let swappedExpectation = changingMetadataSampleFormatBindings(
            of: actualExpectation,
            to: swappedBindings
        )
        let expectation = try await makeOutputExpectation(
            asset: asset,
            trackExpectations: [swappedExpectation],
            metadataTrackCount: 1
        )

        do {
            _ = try await OutputMediaVerifier().verify(
                url: fixture.destination,
                expectation: expectation
            )
            XCTFail("Expected swapped metadata sample-binding rejection.")
        } catch let error as OutputMediaVerificationError {
            guard case .mediaPreservationMismatch(let reason) = error else {
                return XCTFail("Unexpected verification error: \(error)")
            }
            XCTAssertTrue(
                reason.contains("metadata sample-format bindings differ"),
                "Observed rejection reason: \(reason)"
            )
        }
    }

    private func assertRejected(
        shape: StructuralCarrierFixtureShape,
        roles: [OutputMediaTrackPreservationRole],
        reasonContains expectedReasonFragment: String
    ) async throws {
        let fixture = try await makeFixture(shape: shape)
        defer { fixture.remove() }
        let expectation = try await makeExpectation(
            url: fixture.destination,
            roles: roles
        )

        do {
            _ = try await OutputMediaVerifier().verify(
                url: fixture.destination,
                expectation: expectation
            )
            XCTFail("Expected structural-carrier verification rejection.")
        } catch let error as OutputMediaVerificationError {
            guard case .metadataMismatch(let scope, let reason) = error else {
                return XCTFail("Unexpected verification error: \(error)")
            }
            XCTAssertEqual(scope, "timed Mirmir identity")
            XCTAssertTrue(
                reason.contains(expectedReasonFragment),
                "Expected reason containing '\(expectedReasonFragment)', "
                    + "observed '\(reason)'."
            )
        }
    }

    private func makeFixture(
        shape: StructuralCarrierFixtureShape,
        timedMetadata: [String: String]? = nil
    ) async throws -> MediaOutputFixture {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        do {
            try await writeOneFrameVideo(
                to: fixture.source,
                resolution: resolution,
                duration: duration,
                timedMetadata: timedMetadata
            )
            let metadataURL = fixture.directory.appendingPathComponent(
                "carrier-source.mov"
            )
            try await writeStructuralCarrierTrack(
                to: metadataURL,
                shape: shape,
                duration: duration
            )
            try await combineVideoAndCarrierTrack(
                videoURL: fixture.source,
                metadataURLs: [metadataURL],
                destinationURL: fixture.destination
            )
            return fixture
        } catch {
            fixture.remove()
            throw error
        }
    }

    private func makeCarrierAndForeignFixture() async throws
        -> MediaOutputFixture {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        do {
            try await writeOneFrameVideo(
                to: fixture.source,
                resolution: resolution,
                duration: duration
            )
            let carrierURL = fixture.directory.appendingPathComponent(
                "carrier-source.mov"
            )
            let foreignURL = fixture.directory.appendingPathComponent(
                "foreign-source.mov"
            )
            try await writeStructuralCarrierTrack(
                to: carrierURL,
                shape: .strictShell,
                duration: duration
            )
            try await writeStructuralCarrierTrack(
                to: foreignURL,
                shape: .foreignShell,
                duration: duration
            )
            try await combineVideoAndCarrierTrack(
                videoURL: fixture.source,
                metadataURLs: [carrierURL, foreignURL],
                destinationURL: fixture.destination
            )
            return fixture
        } catch {
            fixture.remove()
            throw error
        }
    }

    private func makeHeterogeneousForeignFixture() async throws
        -> MediaOutputFixture {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        do {
            try await writeOneFrameVideo(
                to: fixture.source,
                resolution: resolution,
                duration: duration
            )
            let firstURL = fixture.directory.appendingPathComponent(
                "foreign-first.mov"
            )
            let secondURL = fixture.directory.appendingPathComponent(
                "foreign-second.mov"
            )
            let heterogeneousURL = fixture.directory.appendingPathComponent(
                "foreign-heterogeneous.mov"
            )
            let halfDuration = CMTimeMultiplyByRatio(
                duration,
                multiplier: 1,
                divisor: 2
            )
            try await writeStructuralCarrierTrack(
                to: firstURL,
                shape: .foreignShell,
                duration: halfDuration
            )
            try await writeStructuralCarrierTrack(
                to: secondURL,
                shape: .alternateForeignShell,
                duration: halfDuration
            )
            try await concatenateStructuralMetadataTracks(
                [firstURL, secondURL],
                to: heterogeneousURL
            )
            try await combineVideoAndCarrierTrack(
                videoURL: fixture.source,
                metadataURLs: [heterogeneousURL],
                destinationURL: fixture.destination
            )
            return fixture
        } catch {
            fixture.remove()
            throw error
        }
    }

    private func makeExpectation(
        url: URL,
        roles: [OutputMediaTrackPreservationRole],
        timedMetadata: [String: String] = [:]
    ) async throws -> OutputMediaVerificationExpectation {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let metadataTracks = try await asset.loadTracks(
            withMediaType: .metadata
        )
        var carrierTracks: [AVAssetTrack] = []
        for track in metadataTracks {
            if try await metadataFormatIdentifiers(track).contains(
                MirmirTimedMetadataMigration.shellCarrierIdentifier
            ) {
                carrierTracks.append(track)
            }
        }
        guard carrierTracks.count == 1,
              let track = carrierTracks.first else {
            throw MediaTestFailure.writerFailed
        }
        let commonExpectation = try await makeTrackExpectation(
            asset: asset,
            track: track,
            ordinal: 0,
            role: .ordinary
        )
        let trackExpectations = roles.map { role in
            changingRole(of: commonExpectation, to: role)
        }
        return try await makeOutputExpectation(
            asset: asset,
            trackExpectations: trackExpectations,
            metadataTrackCount: 1,
            timedMetadata: timedMetadata
        )
    }

    private func makeOutputExpectation(
        asset: AVURLAsset,
        trackExpectations: [OutputMediaTrackPreservationExpectation],
        metadataTrackCount: Int,
        timedMetadata: [String: String] = [:]
    ) async throws -> OutputMediaVerificationExpectation {
        let containerMetadata = try await asset.load(.metadata)
        let containerIdentity =
            try await MediaPreservationMetadataIdentityReader.read(
                containerMetadata
            )
        var expectedTrackCounts: [String: Int] = [:]
        for mediaType in SourceMediaPreservationPlanner.preservedMediaTypes {
            expectedTrackCounts[mediaType.rawValue] = 0
        }
        expectedTrackCounts[AVMediaType.video.rawValue] = 1
        expectedTrackCounts[AVMediaType.metadata.rawValue] =
            metadataTrackCount

        return OutputMediaVerificationExpectation(
            resolution: resolution,
            codec: .h264,
            timing: try makeTimingSnapshot(
                presentationTime: .zero,
                duration: duration
            ),
            timedMetadata: timedMetadata,
            mediaPreservation: OutputMediaPreservationExpectation(
                containerMetadata: containerIdentity,
                tracks: trackExpectations,
                associations: [],
                expectedTrackCounts: expectedTrackCounts
            )
        )
    }

    private func makeTrackExpectation(
        asset: AVURLAsset,
        track: AVAssetTrack,
        ordinal: Int,
        role: OutputMediaTrackPreservationRole
    ) async throws -> OutputMediaTrackPreservationExpectation {
        let timeRange = try await track.load(.timeRange)
        let formatDescriptions = try await track.load(.formatDescriptions)
        let metadata = try await track.load(.metadata)
        return OutputMediaTrackPreservationExpectation(
            reference: OutputMediaTrackReference(
                mediaType: AVMediaType.metadata.rawValue,
                ordinal: ordinal
            ),
            role: role,
            timeRange: timeRange,
            naturalTimeScale: try ExactVideoWriterTimeScale.resolve(
                naturalTimeScale: try await track.load(.naturalTimeScale),
                trackTimeRange: timeRange
            ),
            formatSubtypes: formatDescriptions.map {
                CMFormatDescriptionGetMediaSubType($0)
            },
            metadataFormatSchema:
                try OutputMediaMetadataFormatSchemaIdentityReader.read(
                    formatDescriptions
                ),
            metadataSampleFormatBindings:
                try OutputMediaMetadataSampleFormatBindingIdentityReader.read(
                    asset: asset,
                    track: track,
                    cancellationCheck: {
                        try Task.checkCancellation()
                    }
                ),
            totalSampleDataLength:
                try await track.load(.totalSampleDataLength),
            sampleIdentity:
                try await MediaPreservationTrackSampleIdentityReader.read(
                    asset: asset,
                    track: track,
                    cancellationCheck: {
                        try Task.checkCancellation()
                    }
                ),
            linearPCMIdentity: nil,
            appleLosslessIdentity: nil,
            segmentIdentity: nil,
            isEnabled: try await track.load(.isEnabled),
            languageCode: try await track.load(.languageCode),
            extendedLanguageTag:
                try await track.load(.extendedLanguageTag),
            metadata: try await MediaPreservationMetadataIdentityReader.read(
                metadata
            )
        )
    }

    private func changingRole(
        of expectation: OutputMediaTrackPreservationExpectation,
        to role: OutputMediaTrackPreservationRole
    ) -> OutputMediaTrackPreservationExpectation {
        OutputMediaTrackPreservationExpectation(
            reference: expectation.reference,
            role: role,
            timeRange: expectation.timeRange,
            naturalTimeScale: expectation.naturalTimeScale,
            formatSubtypes: expectation.formatSubtypes,
            metadataFormatSchema: expectation.metadataFormatSchema,
            metadataSampleFormatBindings:
                expectation.metadataSampleFormatBindings,
            totalSampleDataLength: expectation.totalSampleDataLength,
            sampleIdentity: expectation.sampleIdentity,
            linearPCMIdentity: expectation.linearPCMIdentity,
            appleLosslessIdentity: expectation.appleLosslessIdentity,
            segmentIdentity: expectation.segmentIdentity,
            isEnabled: expectation.isEnabled,
            languageCode: expectation.languageCode,
            extendedLanguageTag: expectation.extendedLanguageTag,
            metadata: expectation.metadata
        )
    }

    private func changingMetadataSampleFormatBindings(
        of expectation: OutputMediaTrackPreservationExpectation,
        to bindings: OutputMediaMetadataSampleFormatBindingIdentity
    ) -> OutputMediaTrackPreservationExpectation {
        OutputMediaTrackPreservationExpectation(
            reference: expectation.reference,
            role: expectation.role,
            timeRange: expectation.timeRange,
            naturalTimeScale: expectation.naturalTimeScale,
            formatSubtypes: expectation.formatSubtypes,
            metadataFormatSchema: expectation.metadataFormatSchema,
            metadataSampleFormatBindings: bindings,
            totalSampleDataLength: expectation.totalSampleDataLength,
            sampleIdentity: expectation.sampleIdentity,
            linearPCMIdentity: expectation.linearPCMIdentity,
            appleLosslessIdentity: expectation.appleLosslessIdentity,
            segmentIdentity: expectation.segmentIdentity,
            isEnabled: expectation.isEnabled,
            languageCode: expectation.languageCode,
            extendedLanguageTag: expectation.extendedLanguageTag,
            metadata: expectation.metadata
        )
    }

    private func metadataFormatIdentifiers(
        _ track: AVAssetTrack
    ) async throws -> Set<String> {
        Set(
            try await track.load(.formatDescriptions).flatMap {
                description in
                (
                    CMMetadataFormatDescriptionGetIdentifiers(description)
                        as? [String]
                ) ?? []
            }
        )
    }
}

private enum StructuralCarrierFixtureShape: Equatable {
    case strictShell
    case foreignShell
    case alternateForeignShell
    case mixedFormat
    case rawDataCarrier
    case languageCarrier
    case setupDataCarrier
    case changedLocalIDCarrier
    case timedCarrierItem
    case staticCarrierItem
    case multipleEmptyGroups

    var formatIdentifiers: [String] {
        switch self {
        case .foreignShell:
            return ["mdta/org.example.foreign"]
        case .alternateForeignShell:
            return ["mdta/org.example.alternate-foreign"]
        case .mixedFormat:
            return [
                MirmirTimedMetadataMigration.shellCarrierIdentifier,
                "mdta/org.example.foreign"
            ]
        default:
            return [MirmirTimedMetadataMigration.shellCarrierIdentifier]
        }
    }

    func groups(duration: CMTime) -> [AVTimedMetadataGroup] {
        switch self {
        case .timedCarrierItem:
            return [
                AVTimedMetadataGroup(
                    items: [structuralCarrierMetadataItem()],
                    timeRange: CMTimeRange(
                        start: .zero,
                        duration: duration
                    )
                )
            ]
        case .multipleEmptyGroups:
            let quarterDuration = CMTimeMultiplyByRatio(
                duration,
                multiplier: 1,
                divisor: 4
            )
            return [
                AVTimedMetadataGroup(
                    items: [],
                    timeRange: CMTimeRange(
                        start: .zero,
                        duration: quarterDuration
                    )
                ),
                AVTimedMetadataGroup(
                    items: [],
                    timeRange: CMTimeRange(
                        start: CMTimeMultiplyByRatio(
                            duration,
                            multiplier: 1,
                            divisor: 2
                        ),
                        duration: quarterDuration
                    )
                )
            ]
        default:
            return [
                AVTimedMetadataGroup(
                    items: [],
                    timeRange: CMTimeRange(
                        start: .zero,
                        duration: duration
                    )
                )
            ]
        }
    }

    var staticMetadata: [AVMetadataItem] {
        self == .staticCarrierItem
            ? [structuralCarrierMetadataItem()]
            : []
    }
}

private func structuralCarrierMetadataItem() -> AVMetadataItem {
    let identifier =
        MirmirTimedMetadataMigration.shellCarrierIdentifier
    let item = AVMutableMetadataItem()
    item.identifier = AVMetadataIdentifier(rawValue: identifier)
    item.keySpace = .quickTimeMetadata
    item.key = String(identifier.dropFirst("mdta/".count)) as NSString
    item.value = "reserved-carrier-must-not-be-an-item" as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
}

private func writeStructuralCarrierTrack(
    to url: URL,
    shape: StructuralCarrierFixtureShape,
    duration: CMTime
) async throws {
    let formatDescription = try structuralCarrierFormatDescription(
        shape: shape
    )
    let writer: AVAssetWriter
    do {
        writer = try AVAssetWriter(url: url, fileType: .mov)
    } catch {
        throw MediaTestFailure.cannotCreateWriter
    }
    let input = AVAssetWriterInput(
        mediaType: .metadata,
        outputSettings: nil,
        sourceFormatHint: formatDescription
    )
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = 600
    input.metadata = shape.staticMetadata
    guard writer.canAdd(input) else {
        throw MediaTestFailure.cannotAddWriterInput
    }
    writer.add(input)
    let adaptor = AVAssetWriterInputMetadataAdaptor(
        assetWriterInput: input
    )
    guard writer.startWriting() else {
        throw MediaTestFailure.cannotStartWriter
    }
    writer.startSession(atSourceTime: .zero)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    for group in shape.groups(duration: duration) {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard clock.now < deadline,
                  writer.status == .writing else {
                writer.cancelWriting()
                throw MediaTestFailure.writerFailed
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard adaptor.append(group) else {
            writer.cancelWriting()
            throw MediaTestFailure.appendFailed
        }
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: duration)
    await withCheckedContinuation { continuation in
        writer.finishWriting {
            continuation.resume()
        }
    }
    guard writer.status == .completed else {
        throw MediaTestFailure.writerFailed
    }
}

private func structuralCarrierFormatDescription(
    shape: StructuralCarrierFixtureShape
) throws -> CMMetadataFormatDescription {
    let specifications: [[String: Any]] = shape.formatIdentifiers.map {
        identifier in
        var specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier
                as String: identifier,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType
                as String: shape == .rawDataCarrier
                    ? kCMMetadataBaseDataType_RawData as String
                    : kCMMetadataBaseDataType_UTF8 as String
        ]
        if shape == .languageCarrier {
            specification[
                kCMMetadataFormatDescriptionMetadataSpecificationKey_ExtendedLanguageTag
                    as String
            ] = "fr-CA"
        }
        if shape == .setupDataCarrier {
            specification[
                kCMMetadataFormatDescriptionMetadataSpecificationKey_SetupData
                    as String
            ] = Data([0x01, 0x02])
        }
        return specification
    }
    var description: CMMetadataFormatDescription?
    let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: kCFAllocatorDefault,
        metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: specifications as CFArray,
        formatDescriptionOut: &description
    )
    guard status == noErr, let description else {
        throw MediaTestFailure.writerFailed
    }
    guard shape == .changedLocalIDCarrier else { return description }
    guard let extensions = CMFormatDescriptionGetExtensions(description)
            as NSDictionary?,
          let keyTable = extensions[
            kCMFormatDescriptionExtensionKey_MetadataKeyTable as String
          ] as? NSDictionary,
          keyTable.count == 1,
          let entry = keyTable.allValues.first as? NSDictionary else {
        throw MediaTestFailure.writerFailed
    }
    let changedEntry = NSMutableDictionary(dictionary: entry)
    changedEntry[
        kCMMetadataFormatDescriptionKey_LocalID as String
    ] = NSNumber(value: UInt32(7))
    var changedDescription: CMMetadataFormatDescription?
    let changedStatus = CMMetadataFormatDescriptionCreateWithKeys(
        allocator: kCFAllocatorDefault,
        metadataType: kCMMetadataFormatType_Boxed,
        keys: [changedEntry] as CFArray,
        formatDescriptionOut: &changedDescription
    )
    guard changedStatus == noErr, let changedDescription else {
        throw MediaTestFailure.writerFailed
    }
    return changedDescription
}

private func combineVideoAndCarrierTrack(
    videoURL: URL,
    metadataURLs: [URL],
    destinationURL: URL
) async throws {
    let videoAsset = AVURLAsset(
        url: videoURL,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let metadataAssets = metadataURLs.map { metadataURL in
        AVURLAsset(
            url: metadataURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
    }
    let videoAssetTracks = try await videoAsset.load(.tracks)
    let videoTracks = videoAssetTracks.filter { $0.mediaType == .video }
    var metadataTracks: [AVAssetTrack] = []
    for metadataAsset in metadataAssets {
        let tracks = try await metadataAsset.loadTracks(
            withMediaType: .metadata
        )
        guard tracks.count == 1, let track = tracks.first else {
            throw MediaTestFailure.writerFailed
        }
        metadataTracks.append(track)
    }
    guard videoTracks.count == 1,
          metadataTracks.count == metadataURLs.count else {
        throw MediaTestFailure.writerFailed
    }

    let movie = AVMutableMovie()
    movie.timescale = 600
    movie.metadata = try await videoAsset.load(.metadata)
    movie.defaultMediaDataStorage = AVMediaDataStorage(
        url: destinationURL,
        options: nil
    )
    for sourceTrack in videoAssetTracks + metadataTracks {
        guard let destinationTrack = movie.addMutableTrack(
            withMediaType: sourceTrack.mediaType,
            copySettingsFrom: sourceTrack,
            options: nil
        ) else {
            throw MediaTestFailure.cannotAddWriterInput
        }
        let naturalTimeScale = try await sourceTrack.load(
            .naturalTimeScale
        )
        if naturalTimeScale > 0 {
            destinationTrack.timescale = naturalTimeScale
        }
        if sourceTrack.mediaType == .video {
            destinationTrack.preferredTransform = try await sourceTrack.load(
                .preferredTransform
            )
        }
        destinationTrack.isEnabled = try await sourceTrack.load(.isEnabled)
        destinationTrack.languageCode = try await sourceTrack.load(
            .languageCode
        )
        destinationTrack.extendedLanguageTag = try await sourceTrack.load(
            .extendedLanguageTag
        )
        destinationTrack.metadata = try await sourceTrack.load(.metadata)
        let sourceTimeRange = try await sourceTrack.load(.timeRange)
        try destinationTrack.insertTimeRange(
            sourceTimeRange,
            of: sourceTrack,
            at: sourceTimeRange.start,
            copySampleData: true
        )
    }
    try movie.writeHeader(
        to: destinationURL,
        fileType: .mov,
        options: .addMovieHeaderToDestination
    )
    withExtendedLifetime(videoAsset) {}
    withExtendedLifetime(metadataAssets) {}
}

private func concatenateStructuralMetadataTracks(
    _ sourceURLs: [URL],
    to outputURL: URL
) async throws {
    let sourceAssets = sourceURLs.map {
        AVURLAsset(
            url: $0,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
    }
    var sourceTracks: [AVAssetTrack] = []
    for sourceAsset in sourceAssets {
        let tracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        guard tracks.count == 1, let track = tracks.first else {
            throw MediaTestFailure.writerFailed
        }
        sourceTracks.append(track)
    }
    guard let firstTrack = sourceTracks.first else {
        throw MediaTestFailure.writerFailed
    }
    let movie = AVMutableMovie()
    movie.timescale = 600
    movie.defaultMediaDataStorage = AVMediaDataStorage(
        url: outputURL,
        options: nil
    )
    guard let destinationTrack = movie.addMutableTrack(
        withMediaType: .metadata,
        copySettingsFrom: firstTrack,
        options: nil
    ) else {
        throw MediaTestFailure.cannotAddWriterInput
    }
    let naturalTimeScale = try await firstTrack.load(.naturalTimeScale)
    if naturalTimeScale > 0 {
        destinationTrack.timescale = naturalTimeScale
    }
    var insertionTime = CMTime.zero
    for sourceTrack in sourceTracks {
        let sourceTimeRange = try await sourceTrack.load(.timeRange)
        try destinationTrack.insertTimeRange(
            sourceTimeRange,
            of: sourceTrack,
            at: insertionTime,
            copySampleData: true
        )
        insertionTime = CMTimeAdd(
            insertionTime,
            sourceTimeRange.duration
        )
    }
    try movie.writeHeader(
        to: outputURL,
        fileType: .mov,
        options: .addMovieHeaderToDestination
    )
    withExtendedLifetime(sourceAssets) {}
}
