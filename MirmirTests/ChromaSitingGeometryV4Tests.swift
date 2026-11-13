import CoreVideo
import CoreMedia
import Foundation
import XCTest
@testable import Mirmir

final class ChromaSitingGeometryV4Tests: XCTestCase {
    func testFieldPairIdentityRetainsBothSourcesAndTheCommonOutput() {
        let fields = SpatialInterlacedChromaGeometryV4(
            topSource: .left, bottomSource: .center, target: .left
        )
        XCTAssertEqual(fields.geometry(forTopField: true),
                       SpatialChromaGeometryV4(source: .left, target: .left))
        XCTAssertEqual(fields.geometry(forTopField: false),
                       SpatialChromaGeometryV4(source: .center, target: .left))
        XCTAssertNotEqual(fields.identity, SpatialInterlacedChromaGeometryV4(
            topSource: .center, bottomSource: .left, target: .left
        ).identity)
        XCTAssertNotEqual(fields.identity, SpatialInterlacedChromaGeometryV4(
            topSource: .left, bottomSource: .center, target: .center
        ).identity)
    }

    func testMixedFieldsUseTheirOwnLocationAndRejectDifferentFieldRecovery() async throws {
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("field-phase-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }
        let runtime = try ASHV4SemanticArtifactTestSupport.buildAndLoad(at: runtimeDirectory)
        let fields = SpatialInterlacedChromaGeometryV4(
            topSource: .left, bottomSource: .center, target: .left
        )
        func configuration(_ fields: SpatialInterlacedChromaGeometryV4)
            -> DeterministicPreparedConfigurationV4 {
            DeterministicPreparedConfigurationV4(
                backendID: .mirmirDeterministicCPU, executionBackend: .cpu,
                storage: .nv12VideoRange8Bit, sourceWidth: 32, sourceHeight: 24,
                targetWidth: 64, targetHeight: 48, scanMode: .interlaced(.topFieldFirst),
                chromaGeometry: fields.geometry(forTopField: true),
                interlacedChromaGeometry: fields
            )
        }
        let engine = try PreparedDeterministicV4Upscaler(
            configuration: configuration(fields), runtime: runtime
        )
        let source = try makeBuffer(width: 32, height: 24)
        try fill(source)
        CVBufferSetAttachment(source, kCVImageBufferFieldCountKey,
                              NSNumber(value: 2), .shouldPropagate)
        CVBufferSetAttachment(source, kCVImageBufferChromaLocationTopFieldKey,
                              kCVImageBufferChromaLocation_Left, .shouldPropagate)
        CVBufferSetAttachment(source, kCVImageBufferChromaLocationBottomFieldKey,
                              kCVImageBufferChromaLocation_Center, .shouldPropagate)
        let destinations = try (0..<2).map { _ in
            FramePixelBuffer(try makeBuffer(width: 64, height: 48))
        }
        let outputs = try await engine.processTemporal(
            source: FramePixelBuffer(source), destinations: destinations,
            timing: FrameTiming(frameIndex: 0, presentationTime: .zero,
                                duration: CMTime(value: 1, timescale: 30))
        )
        XCTAssertEqual(outputs.map(\.sourceField), [.top, .bottom])
        XCTAssertEqual(try visiblePlanes(destinations[0].value)[1][3 * 2], 119)
        XCTAssertEqual(try visiblePlanes(destinations[1].value)[1][3 * 2], 105)
        for destination in destinations {
            XCTAssertEqual(CVBufferCopyAttachment(destination.value,
                kCVImageBufferChromaLocationTopFieldKey, nil) as? String, "Left")
            XCTAssertNil(CVBufferCopyAttachment(destination.value,
                kCVImageBufferChromaLocationBottomFieldKey, nil))
        }
        let plan = ASHSHA256V4(rawData: Data("mixed-field-recovery-test".utf8))
        let checkpoint = try await engine.makeTemporalCheckpoint(
            planSHA256: plan, lastCompletedInputOrdinal: 0
        )
        let changed = try PreparedDeterministicV4Upscaler(
            configuration: configuration(SpatialInterlacedChromaGeometryV4(
                topSource: .left, bottomSource: .top, target: .left
            )), runtime: runtime
        )
        do {
            try await changed.restoreTemporalCheckpoint(checkpoint, planSHA256: plan)
            XCTFail("A checkpoint with a different physical bottom-field phase was accepted")
        } catch let error as ASHPreparedTemporalCheckpointV4Error {
            XCTAssertEqual(error, .identityMismatch)
        }
        try await engine.finish()
        try await changed.finish()
    }

    func testStaticMixedFieldTemporalVotesAreAlignedBeforeAdaptiveComparison() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaptive-field-phase-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try ASHV4SemanticArtifactTestSupport.buildAndLoad(at: directory)
        let fields = SpatialInterlacedChromaGeometryV4(
            topSource: .left, bottomSource: .center, target: .left
        )
        let engine = try PreparedDeterministicV4Upscaler(
            configuration: DeterministicPreparedConfigurationV4(
                backendID: .mirmirDeterministicCPU, executionBackend: .cpu,
                storage: .nv12VideoRange8Bit, sourceWidth: 64, sourceHeight: 48,
                targetWidth: 96, targetHeight: 72, scanMode: .interlaced(.topFieldFirst),
                chromaGeometry: fields.geometry(forTopField: true),
                interlacedChromaGeometry: fields
            ), runtime: runtime
        )
        let source = try makeBuffer(width: 64, height: 48)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(source, []), kCVReturnSuccess)
        let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, 0))
            .assumingMemoryBound(to: UInt8.self)
        let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, 1))
            .assumingMemoryBound(to: UInt8.self)
        for row in 0..<48 { for x in 0..<64 {
            y[row * CVPixelBufferGetBytesPerRowOfPlane(source, 0) + x] = 96
        }}
        // One continuous static signal U(x_luma)=80+2*x_luma, sampled at each
        // physical field's own location; V and luma are constant.
        for row in 0..<24 { for x in 0..<32 {
            let offset = row * CVPixelBufferGetBytesPerRowOfPlane(source, 1) + x * 2
            uv[offset] = UInt8(80 + x * 4 + row % 2)
            uv[offset + 1] = 160
        }}
        CVPixelBufferUnlockBaseAddress(source, [])
        CVBufferSetAttachment(source, kCVImageBufferFieldCountKey,
                              NSNumber(value: 2), .shouldPropagate)
        CVBufferSetAttachment(source, kCVImageBufferChromaLocationTopFieldKey,
                              kCVImageBufferChromaLocation_Left, .shouldPropagate)
        CVBufferSetAttachment(source, kCVImageBufferChromaLocationBottomFieldKey,
                              kCVImageBufferChromaLocation_Center, .shouldPropagate)
        // Complete border-inclusive UV goldens from the independent exact
        // Fraction/Q14 oracle; first-frame bob and later adaptive votes differ
        // at the declared reflection borders, so both are bound separately.
        let first = [
            "1bd05007d0c677152e14434587c880795cdf7a82be230a8d467f6bd42095ecc8",
            "30b31c9bafea6011c679878cd437db86a89d0758329a72dd66e97a6c21f5c963"
        ]
        let adaptive = [
            "599a83d8c4d0e1fdf5fb6cc8fac28c6945eb7805859a7ba62ee09d629d1eaf56",
            "ff173f24af3c062bbf6487df011ef44f54080aa4ca104a2d0f0dec9b83aac994"
        ]
        for frame in 0..<4 {
            let destinations = try (0..<2).map { _ in
                FramePixelBuffer(try makeBuffer(width: 96, height: 72))
            }
            _ = try await engine.processTemporal(
                source: FramePixelBuffer(source), destinations: destinations,
                timing: FrameTiming(frameIndex: frame,
                    presentationTime: CMTime(value: Int64(frame), timescale: 30),
                    duration: CMTime(value: 1, timescale: 30))
            )
            for field in 0..<2 {
                let actual = try visiblePlanes(destinations[field].value)[1]
                XCTAssertEqual(ASHSHA256V4(rawData: actual).rawValue,
                               (frame == 0 ? first : adaptive)[field],
                               "frame\(frame), physicalfield\(field)")
            }
        }
        try await engine.finish()
    }

    func testPhysicalCoordinatesUseAuthenticatedLumaExtentsAndLocations() throws {
        let cases: [(SpatialChromaSitingV4, SpatialAxisV4, Int, Int, Int, Int64, Int64)] = [
            (.left, .horizontal, 128, 256, 0, -1, 8),
            (.center, .horizontal, 128, 256, 0, -1, 4),
            (.left, .horizontal, 128, 512, 0, -3, 16),
            (.topLeft, .vertical, 96, 384, 0, -3, 16),
            (.left, .vertical, 96, 384, 0, -3, 8),
            (.left, .horizontal, 31, 47, 0, -4, 47),
            (.center, .horizontal, 31, 47, 0, -8, 47),
            (.left, .horizontal, 31, 47, 23, 709, 47),
            (.center, .horizontal, 31, 47, 23, 15, 1),
            (.left, .vertical, 19, 29, 0, -5, 29)
        ]
        for (siting, axis, source, target, index, numerator, denominator) in cases {
            let mapping = try SpatialSubsampledLumaMappingV4(
                axis: axis, sourceLumaExtent: source, targetLumaExtent: target,
                geometry: SpatialChromaGeometryV4(source: siting, target: siting)
            )
            XCTAssertEqual(
                try mapping.sourceCoordinate(destinationIndex: index),
                try ExactRationalV4(numerator, denominator),
                "\(siting) \(axis) \(source)→\(target) index\(index)"
            )
        }
        let conversion = try SpatialSubsampledLumaMappingV4(
            axis: .horizontal, sourceLumaExtent: 128, targetLumaExtent: 256,
            geometry: SpatialChromaGeometryV4(source: .left, target: .center)
        )
        XCTAssertEqual(try conversion.sourceCoordinate(destinationIndex: 0), .zero)
    }

    func testSchemaTwoAuthenticatesGeometryEvenWhenPlaneCountsAreUnchanged() throws {
        let plan = try SpatialScalePlanV4(
            sourceLumaWidth: 31, sourceLumaHeight: 19,
            targetLumaWidth: 47, targetLumaHeight: 29,
            chromaGeometry: SpatialChromaGeometryV4(source: .left, target: .left),
            borderRule: .reflect101
        )
        let encoded = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(SpatialScalePlanV4.self, from: encoded), plan)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for replacement in ["sourceLumaExtent": 32, "targetLumaExtent": 48] {
            var object = original
            var horizontal = try XCTUnwrap(object["horizontal"] as? [String: Any])
            var mapping = try XCTUnwrap(horizontal["subsampledLumaMapping"] as? [String: Any])
            mapping[replacement.key] = replacement.value
            horizontal["subsampledLumaMapping"] = mapping
            object["horizontal"] = horizontal
            XCTAssertThrowsError(try JSONDecoder().decode(
                SpatialScalePlanV4.self, from: JSONSerialization.data(withJSONObject: object)
            ))
        }
        var mixed = original
        mixed["schemaVersion"] = 1
        XCTAssertThrowsError(try JSONDecoder().decode(
            SpatialScalePlanV4.self, from: JSONSerialization.data(withJSONObject: mixed)
        ))
        let generic = try SpatialScalePlanV4(
            sourceWidth: 16, sourceHeight: 10, targetWidth: 24, targetHeight: 15
        )
        XCTAssertNotEqual(generic, plan)
    }

    func testCorrectedLeftEdgeChangesOnlyChromaAndRetainsSource() async throws {
        let source = try makeBuffer(width: 8, height: 6)
        try fill(source)
        CVBufferSetAttachment(source, kCVImageBufferChromaLocationTopFieldKey,
                              kCVImageBufferChromaLocation_Left, .shouldPropagate)
        let before = try visiblePlanes(source)
        let corrected = try makeBuffer(width: 16, height: 12)
        let generic = try makeBuffer(width: 16, height: 12)
        let geometry = SpatialChromaGeometryV4(source: .left, target: .left)
        let prepared = try scaler(geometry: geometry)
        try await prepared.process(source: source, destination: corrected)
        try await scaler(geometry: nil).process(source: source, destination: generic)
        let actual = try visiblePlanes(corrected)
        let old = try visiblePlanes(generic)
        XCTAssertEqual(actual[0], old[0])
        XCTAssertEqual(actual[1][3 * 2], 119)
        XCTAssertEqual(old[1][3 * 2], 111)
        XCTAssertEqual(try visiblePlanes(source), before)
        XCTAssertEqual(prepared.hotPathDiagnostics().completedFrameCount, 1)
    }

    func testContradictoryPhaseAndInterlacedFramesFailBeforeAnyWrite() async throws {
        let prepared = try scaler(geometry: SpatialChromaGeometryV4(source: .left, target: .left))
        for interlaced in [false, true] {
            let source = try makeBuffer(width: 8, height: 6)
            try fill(source)
            if interlaced {
                CVBufferSetAttachment(source, kCVImageBufferFieldCountKey,
                                      NSNumber(value: 2), .shouldPropagate)
                XCTAssertEqual((CVBufferCopyAttachment(source, kCVImageBufferFieldCountKey, nil)
                                as? NSNumber)?.intValue, 2)
            } else {
                CVBufferSetAttachment(source, kCVImageBufferChromaLocationTopFieldKey,
                                      kCVImageBufferChromaLocation_Center, .shouldPropagate)
                XCTAssertEqual(CVBufferCopyAttachment(source, kCVImageBufferChromaLocationTopFieldKey, nil)
                                as? String, kCVImageBufferChromaLocation_Center as String)
            }
            let output = try makeBuffer(width: 16, height: 12)
            try fill(output)
            CVBufferSetAttachment(output, "qa-marker" as CFString,
                                  "unchanged" as CFString, .shouldNotPropagate)
            let before = try visiblePlanes(output)
            do {
                try await prepared.process(source: source, destination: output)
                XCTFail("Contradictory authenticated geometry was accepted")
            } catch let error as FixedPointPixelBufferScalerV4Error {
                if interlaced { XCTAssertEqual(error, .nonProgressiveChromaGeometry) }
                else { XCTAssertEqual(error, .chromaSitingMismatch(expected: .left, actual: "Center")) }
            }
            XCTAssertEqual(try visiblePlanes(output), before)
            var mode = CVAttachmentMode.shouldPropagate
            XCTAssertEqual(CVBufferCopyAttachment(output, "qa-marker" as CFString, &mode) as? String,
                           "unchanged")
            XCTAssertEqual(mode, .shouldNotPropagate)
        }
        XCTAssertEqual(prepared.hotPathDiagnostics().completedFrameCount, 0)
        let authenticatedUntaggedSource = try makeBuffer(width: 8, height: 6)
        try fill(authenticatedUntaggedSource)
        let output = try makeBuffer(width: 16, height: 12)
        try await prepared.process(source: authenticatedUntaggedSource, destination: output)
        XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferChromaLocationTopFieldKey, nil)
                        as? String, kCVImageBufferChromaLocation_Left as String)
        XCTAssertEqual(prepared.hotPathDiagnostics().completedFrameCount, 1)
    }

    private func scaler(geometry: SpatialChromaGeometryV4?) throws -> FixedPointPixelBufferScalerV4 {
        try FixedPointPixelBufferScalerV4(
            backend: .cpu, storage: .nv12VideoRange8Bit,
            sourceWidth: 8, sourceHeight: 6, targetWidth: 16, targetHeight: 12,
            borderRule: .reflect101, chromaGeometry: geometry
        )
    }

    private func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &result), kCVReturnSuccess)
        return try XCTUnwrap(result)
    }

    private func fill(_ buffer: CVPixelBuffer) throws {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        for row in 0..<height { for column in 0..<width {
            y[row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + column] = UInt8(48 + (column * 3 + row) % 128)
        }}
        for row in 0..<((height + 1) / 2) { for column in 0..<((width + 1) / 2) {
            let offset = row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + column * 2
            uv[offset] = column < 2 ? 100 : 156
            uv[offset + 1] = 128
        }}
    }

    private func visiblePlanes(_ buffer: CVPixelBuffer) throws -> [Data] {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return try (0..<2).map { plane in
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                .assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            var result = Data()
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                result.append(base.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)), count: rowBytes)
            }
            return result
        }
    }
}
