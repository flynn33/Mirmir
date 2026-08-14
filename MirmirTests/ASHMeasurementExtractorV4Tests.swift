import CoreVideo
import XCTest
@testable import Mirmir

final class ASHMeasurementExtractorV4Tests: XCTestCase {
    func testConstantNeutralNV12ProducesExactDeclaredEvidenceAndState() throws {
        let frame = try makeFrame(
            storage: .nv12VideoRange8Bit,
            width: 7,
            height: 5,
            luma: { _, _ in 126 },
            cb: { _, _ in 128 },
            cr: { _, _ in 128 }
        )
        let result = try ASHMeasurementExtractorV4.extract(
            frame: frame,
            previousFrame: nil,
            contract: .canonicalP06,
            history: .reset(.streamStart)
        )
        let evidence = result.projection.evidence
        XCTAssertEqual(result.normalizedLumaWindowQ16.count, 32 * 32)
        XCTAssertEqual(Set(result.normalizedLumaWindowQ16).count, 1)
        XCTAssertEqual(evidence.rmsContrast, .zero)
        XCTAssertEqual(evidence.edgeEnergy, .zero)
        XCTAssertEqual(evidence.textureEnergy, .zero)
        XCTAssertEqual(evidence.chromaEnergy, .zero)
        XCTAssertEqual(evidence.horizontalGradientEnergy, .zero)
        XCTAssertEqual(evidence.verticalGradientEnergy, .zero)
        XCTAssertEqual(evidence.temporalChange, .zero)
        XCTAssertEqual(
            result.projection.payloadBitsByCoordinate,
            [1, 0, 0, 0, 0, 0, 0, 0]
        )
        XCTAssertTrue(result.projection.state.hasValidIntegrity)
    }

    func testEquivalentNV12AndP010CodesProjectToTheSameState() throws {
        let nv12 = try makeFrame(
            storage: .nv12VideoRange8Bit,
            width: 32,
            height: 32,
            luma: { x, y in UInt16(16 + ((x * 7 + y * 3) % 220)) },
            cb: { x, _ in UInt16(96 + x % 64) },
            cr: { _, y in UInt16(96 + y % 64) }
        )
        let p010 = try makeFrame(
            storage: .p010VideoRange10Bit,
            width: 32,
            height: 32,
            luma: { x, y in
                let code = UInt16(16 + ((x * 7 + y * 3) % 220))
                return 64 + (code - 16) * 4
            },
            cb: { x, _ in UInt16(384 + (x % 64) * 4) },
            cr: { _, y in UInt16(384 + (y % 64) * 4) }
        )
        let first = try ASHMeasurementExtractorV4.extract(
            frame: nv12,
            previousFrame: nil,
            contract: .canonicalP06,
            history: .reset(.streamStart)
        )
        let second = try ASHMeasurementExtractorV4.extract(
            frame: p010,
            previousFrame: nil,
            contract: .canonicalP06,
            history: .reset(.streamStart)
        )
        XCTAssertEqual(first.normalizedLumaWindowQ16, second.normalizedLumaWindowQ16)
        XCTAssertEqual(first.projection.evidence, second.projection.evidence)
        XCTAssertEqual(first.projection.state, second.projection.state)
    }

    func testTemporalEvidenceAndHysteresisUseOnlyPastFrame() throws {
        let dark = try makeFrame(
            storage: .nv12FullRange8Bit,
            width: 4,
            height: 4,
            luma: { _, _ in 0 },
            cb: { _, _ in 128 },
            cr: { _, _ in 128 }
        )
        let bright = try makeFrame(
            storage: .nv12FullRange8Bit,
            width: 4,
            height: 4,
            luma: { _, _ in 255 },
            cb: { _, _ in 128 },
            cr: { _, _ in 128 }
        )
        let initial = try ASHMeasurementExtractorV4.extract(
            frame: dark,
            previousFrame: nil,
            contract: .canonicalP06,
            history: .reset(.streamStart)
        )
        let changed = try ASHMeasurementExtractorV4.extract(
            frame: bright,
            previousFrame: dark,
            contract: .canonicalP06,
            history: .continuous(previousState: initial.projection.state)
        )
        XCTAssertEqual(changed.projection.evidence.temporalChange, .one)
        XCTAssertEqual(changed.projection.bit(for: .temporalChange), 1)
        XCTAssertEqual(changed.projection.bit(for: .meanLuminance), 1)
        XCTAssertTrue(changed.projection.state.hasValidIntegrity)
    }

    func testMotionCompensatedTemporalEvidenceOverridesColocatedFallback() throws {
        let previous = try makeFrame(
            storage: .nv12FullRange8Bit,
            width: 8,
            height: 8,
            luma: { x, y in UInt16((x * 29 + y * 17) & 0xff) },
            cb: { _, _ in 128 },
            cr: { _, _ in 128 }
        )
        let current = try makeFrame(
            storage: .nv12FullRange8Bit,
            width: 8,
            height: 8,
            luma: { x, y in UInt16(((x + 1) * 29 + y * 17) & 0xff) },
            cb: { _, _ in 128 },
            cr: { _, _ in 128 }
        )
        let prior = try ASHMeasurementExtractorV4.extract(
            frame: previous,
            previousFrame: nil,
            contract: .canonicalP06,
            history: .reset(.streamStart)
        )
        let fallback = try ASHMeasurementExtractorV4.extract(
            frame: current,
            previousFrame: previous,
            contract: .canonicalP06,
            history: .continuous(previousState: prior.projection.state)
        )
        let declaredMotionResidual: UInt32 = 2_048
        let compensated = try ASHMeasurementExtractorV4.extract(
            frame: current,
            previousFrame: previous,
            contract: .canonicalP06,
            history: .continuous(previousState: prior.projection.state),
            motionCompensatedTemporalEvidenceQ16: declaredMotionResidual
        )

        XCTAssertNotEqual(
            fallback.projection.evidence.temporalChange.rawValue,
            declaredMotionResidual
        )
        XCTAssertEqual(
            compensated.projection.evidence.temporalChange.rawValue,
            declaredMotionResidual
        )
    }

    func testOutOfRangeMotionCompensatedTemporalEvidenceFailsClosed() throws {
        let frame = try makeFrame(
            storage: .nv12FullRange8Bit,
            width: 4,
            height: 4,
            luma: { _, _ in 128 },
            cb: { _, _ in 128 },
            cr: { _, _ in 128 }
        )
        XCTAssertThrowsError(
            try ASHMeasurementExtractorV4.extract(
                frame: frame,
                previousFrame: nil,
                contract: .canonicalP06,
                history: .reset(.streamStart),
                motionCompensatedTemporalEvidenceQ16:
                    ASHNormalizedQ16V4.scale + 1
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHMeasurementExtractorV4Error,
                .invalidTemporalEvidence(ASHNormalizedQ16V4.scale + 1)
            )
        }
    }

    func testHistoryGeometryMismatchFailsClosed() throws {
        let first = try makeFrame(
            storage: .nv12VideoRange8Bit,
            width: 4,
            height: 4,
            luma: { _, _ in 64 },
            cb: { _, _ in 128 },
            cr: { _, _ in 128 }
        )
        let other = try makeFrame(
            storage: .nv12VideoRange8Bit,
            width: 5,
            height: 4,
            luma: { _, _ in 64 },
            cb: { _, _ in 128 },
            cr: { _, _ in 128 }
        )
        XCTAssertThrowsError(
            try ASHMeasurementExtractorV4.extract(
                frame: first,
                previousFrame: other,
                contract: .canonicalP06,
                history: .continuous(
                    previousState: try ASHState(
                        payloadBits: Array(repeating: 0, count: 8)
                    )
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHMeasurementExtractorV4Error,
                .incompatibleHistory
            )
        }
    }

    func testDirectCompactMeasurementIsExactAcrossEveryStorage() throws {
        for storage in PixelStorageV4.allCases {
            let firstFrame = try makePatternFrame(
                storage: storage,
                width: 7,
                height: 5,
                phase: 3
            )
            let secondFrame = try makePatternFrame(
                storage: storage,
                width: 7,
                height: 5,
                phase: 11
            )
            let firstBuffer = try makeBuffer(frame: firstFrame)
            let secondBuffer = try makeBuffer(frame: secondFrame)
            let referenceFirst = try ASHMeasurementExtractorV4.extract(
                frame: firstFrame,
                previousFrame: nil,
                contract: .canonicalP06,
                history: .reset(.streamStart)
            )
            var workspace = ASHMeasurementExtractionWorkspaceV4()
            let directFirst = try ASHMeasurementExtractorV4.extractDirect(
                buffer: firstBuffer,
                storage: storage,
                previousHistory: nil,
                contract: .canonicalP06,
                history: .reset(.streamStart),
                workspace: &workspace
            )
            XCTAssertEqual(directFirst.extracted, referenceFirst)

            let referenceSecond = try ASHMeasurementExtractorV4.extract(
                frame: secondFrame,
                previousFrame: firstFrame,
                contract: .canonicalP06,
                history: .continuous(
                    previousState: referenceFirst.projection.state
                )
            )
            let directSecond = try ASHMeasurementExtractorV4.extractDirect(
                buffer: secondBuffer,
                storage: storage,
                previousHistory: directFirst.compactHistory,
                contract: .canonicalP06,
                history: .continuous(
                    previousState: directFirst.extracted.projection.state
                ),
                workspace: &workspace
            )
            XCTAssertEqual(directSecond.extracted, referenceSecond)
            XCTAssertEqual(
                directSecond.compactHistory.normalizedLumaWindowQ16,
                referenceSecond.normalizedLumaWindowQ16
            )
            XCTAssertEqual(workspace.signalWindow.windowSampleCount, 32 * 32)
            XCTAssertLessThanOrEqual(workspace.retainedByteUpperBound, 14 * 1_024)
        }
    }

    func testCompactMeasurementHistoryCanonicalDecodeRejectsTampering()
        throws {
        let history = try ASHCompactMeasurementHistoryV4(
            storage: .p010VideoRange10Bit,
            sourceWidth: 1_920,
            sourceHeight: 1_080,
            windowWidth: 2,
            windowHeight: 2,
            normalizedLumaWindowQ16: [
                0,
                1,
                ASHNormalizedQ16V4.scale - 1,
                ASHNormalizedQ16V4.scale
            ]
        )
        let canonical = try ASHCanonicalJSONV4.encode(history)
        let decoded = try ASHCanonicalJSONV4.decode(
            ASHCompactMeasurementHistoryV4.self,
            from: canonical
        )
        XCTAssertEqual(decoded, history)
        XCTAssertEqual(Set([decoded, history]).count, 1)
        XCTAssertNoThrow(try decoded.validate())

        let invalidCount = try replacingCanonicalUTF8(
            "\"normalizedLumaWindowQ16\":[0,1,65535,65536]",
            with: "\"normalizedLumaWindowQ16\":[0,1,65535]",
            in: canonical
        )
        let decodedInvalidCount = try ASHCanonicalJSONV4.decode(
            ASHCompactMeasurementHistoryV4.self,
            from: invalidCount
        )
        XCTAssertThrowsError(try decodedInvalidCount.validate()) { error in
            XCTAssertEqual(
                error as? ASHMeasurementExtractorV4Error,
                .incompatibleHistory
            )
        }

        let invalidQ16 = try replacingCanonicalUTF8(
            "\"normalizedLumaWindowQ16\":[0,1,65535,65536]",
            with: "\"normalizedLumaWindowQ16\":[0,1,65535,65537]",
            in: canonical
        )
        let decodedInvalidQ16 = try ASHCanonicalJSONV4.decode(
            ASHCompactMeasurementHistoryV4.self,
            from: invalidQ16
        )
        XCTAssertThrowsError(try decodedInvalidQ16.validate()) { error in
            XCTAssertEqual(
                error as? ASHMeasurementExtractorV4Error,
                .incompatibleHistory
            )
        }

        let invalidGeometry = try replacingCanonicalUTF8(
            "\"sourceWidth\":1920",
            with: "\"sourceWidth\":0",
            in: canonical
        )
        let decodedInvalidGeometry = try ASHCanonicalJSONV4.decode(
            ASHCompactMeasurementHistoryV4.self,
            from: invalidGeometry
        )
        XCTAssertThrowsError(try decodedInvalidGeometry.validate()) { error in
            XCTAssertEqual(
                error as? ASHMeasurementExtractorV4Error,
                .incompatibleHistory
            )
        }
    }

    func testDirectLumaReadWritePreservesChromaAndPaddingExactly() throws {
        for storage in PixelStorageV4.allCases {
            let frame = try makePatternFrame(
                storage: storage,
                width: 13,
                height: 7,
                phase: 5
            )
            let buffer = try makeBuffer(frame: frame)
            try fillPadding(in: buffer, storage: storage, byte: 0xa5)
            var workspace = PixelBufferLumaWorkspaceV4()
            try PixelBufferSignalCodecV4.readLuma(
                buffer,
                storage: storage,
                into: &workspace
            )
            XCTAssertEqual(workspace.samples, frame.planes[0].samples)
            let firstIdentity = workspace.storageIdentity
            let firstAllocationCount = workspace.storageAllocationCount
            try PixelBufferSignalCodecV4.readLuma(
                buffer,
                storage: storage,
                into: &workspace
            )
            XCTAssertEqual(workspace.storageIdentity, firstIdentity)
            XCTAssertEqual(
                workspace.storageAllocationCount,
                firstAllocationCount
            )

            let beforeLuma = try rawPlaneBytes(buffer, plane: 0)
            let beforeChroma = try rawPlaneBytes(buffer, plane: 1)
            let bounds = PixelLayoutV4(storage: storage)
                .planes[0].signalCodeBounds[0]
            let replacement = workspace.samples.enumerated().map { index, value in
                let offset = Int(value - bounds.minimum)
                let range = Int(bounds.maximum - bounds.minimum) + 1
                return bounds.minimum + UInt16((offset + index * 7 + 1) % range)
            }
            let plane = try ASHTemporalPlaneV4(
                width: workspace.width,
                height: workspace.height,
                minimumCode: bounds.minimum,
                maximumCode: bounds.maximum,
                samples: replacement
            )
            try PixelBufferSignalCodecV4.writeLuma(
                plane,
                to: buffer,
                storage: storage
            )
            let afterLuma = try rawPlaneBytes(buffer, plane: 0)
            let afterChroma = try rawPlaneBytes(buffer, plane: 1)
            XCTAssertEqual(afterChroma, beforeChroma)
            let activeBytes = frame.width * storage.bytesPerComponent
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in 0..<frame.height {
                XCTAssertEqual(
                    beforeLuma[(y * stride + activeBytes)..<((y + 1) * stride)],
                    afterLuma[(y * stride + activeBytes)..<((y + 1) * stride)]
                )
            }
            try PixelBufferSignalCodecV4.readLuma(
                buffer,
                storage: storage,
                into: &workspace
            )
            XCTAssertEqual(workspace.samples, replacement)
        }
    }

    func testTwoRotatingLumaWorkspacesRemainStableAndDetectRetainedCOW()
        throws {
        let storage = PixelStorageV4.p010FullRange10Bit
        let buffers = try [2, 9].map { phase in
            try makeBuffer(frame: makePatternFrame(
                storage: storage,
                width: 16,
                height: 12,
                phase: phase
            ))
        }
        var first = PixelBufferLumaWorkspaceV4()
        var second = PixelBufferLumaWorkspaceV4()
        var history = try ASHTemporalHistoryV4(capacity: 1)
        try PixelBufferSignalCodecV4.readLuma(
            buffers[0],
            storage: storage,
            into: &first
        )
        try history.append(makeTemporalFrame(
            id: "rotation-0",
            ordinal: 0,
            plane: first.temporalPlane()
        ))
        try PixelBufferSignalCodecV4.readLuma(
            buffers[1],
            storage: storage,
            into: &second
        )
        try history.append(makeTemporalFrame(
            id: "rotation-1",
            ordinal: 1,
            plane: second.temporalPlane()
        ))
        let firstIdentity = first.storageIdentity
        let secondIdentity = second.storageIdentity
        let firstAllocations = first.storageAllocationCount
        let secondAllocations = second.storageAllocationCount

        for ordinal in 2..<10 {
            if ordinal.isMultiple(of: 2) {
                try PixelBufferSignalCodecV4.readLuma(
                    buffers[0], storage: storage, into: &first
                )
                try history.append(makeTemporalFrame(
                    id: "rotation-\(ordinal)",
                    ordinal: Int64(ordinal),
                    plane: first.temporalPlane()
                ))
            } else {
                try PixelBufferSignalCodecV4.readLuma(
                    buffers[1], storage: storage, into: &second
                )
                try history.append(makeTemporalFrame(
                    id: "rotation-\(ordinal)",
                    ordinal: Int64(ordinal),
                    plane: second.temporalPlane()
                ))
            }
        }
        XCTAssertEqual(first.storageIdentity, firstIdentity)
        XCTAssertEqual(second.storageIdentity, secondIdentity)
        XCTAssertEqual(first.storageAllocationCount, firstAllocations)
        XCTAssertEqual(second.storageAllocationCount, secondAllocations)
        XCTAssertEqual(history.frames.count, 1)

        let retained = try first.temporalPlane()
        let beforeRetainedReuse = first.storageAllocationCount
        try PixelBufferSignalCodecV4.readLuma(
            buffers[0], storage: storage, into: &first
        )
        XCTAssertEqual(
            first.storageAllocationCount,
            beforeRetainedReuse + 1
        )
        XCTAssertEqual(retained.samples.count, 16 * 12)
    }

    func testCancelledDirectLumaWriteLeavesEveryByteUnchanged() async throws {
        let storage = PixelStorageV4.nv12VideoRange8Bit
        let frame = try makePatternFrame(
            storage: storage,
            width: 13,
            height: 7,
            phase: 4
        )
        let buffer = try makeBuffer(frame: frame)
        try fillPadding(in: buffer, storage: storage, byte: 0x6d)
        let before = try allPlaneBytes(buffer)
        var workspace = PixelBufferLumaWorkspaceV4()
        try PixelBufferSignalCodecV4.readLuma(
            buffer, storage: storage, into: &workspace
        )
        let error = await Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try PixelBufferSignalCodecV4.writeLuma(
                    from: workspace,
                    to: buffer,
                    storage: storage
                )
                return nil
            } catch {
                return error
            }
        }.value
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(try allPlaneBytes(buffer), before)
    }

    private func makePatternFrame(
        storage: PixelStorageV4,
        width: Int,
        height: Int,
        phase: Int
    ) throws -> PixelBufferSignalFrameV4 {
        let layout = PixelLayoutV4(storage: storage)
        let lumaBounds = layout.planes[0].signalCodeBounds[0]
        let chromaBounds = layout.planes[1].signalCodeBounds[0]
        let lumaRange = Int(lumaBounds.maximum - lumaBounds.minimum) + 1
        let chromaRange = Int(chromaBounds.maximum - chromaBounds.minimum) + 1
        let luma: (Int, Int) -> UInt16 = { x, y in
            let offset = (x * 37 + y * 61 + phase * 19) % lumaRange
            return lumaBounds.minimum + UInt16(offset)
        }
        let cb: (Int, Int) -> UInt16 = { x, y in
            let offset = (x * 23 + y * 11 + phase * 7) % chromaRange
            return chromaBounds.minimum + UInt16(offset)
        }
        let cr: (Int, Int) -> UInt16 = { x, y in
            let offset = (x * 5 + y * 29 + phase * 13) % chromaRange
            return chromaBounds.minimum + UInt16(offset)
        }
        return try makeFrame(
            storage: storage,
            width: width,
            height: height,
            luma: luma,
            cb: cb,
            cr: cr
        )
    }

    private func makeBuffer(
        frame: PixelBufferSignalFrameV4
    ) throws -> CVPixelBuffer {
        let buffer = try PixelBufferSignalCodecV4.makeBuffer(
            storage: frame.storage,
            width: frame.width,
            height: frame.height,
            metalCompatible: false
        )
        try PixelBufferSignalCodecV4.write(frame, to: buffer)
        return buffer
    }

    private func fillPadding(
        in buffer: CVPixelBuffer,
        storage: PixelStorageV4,
        byte: UInt8
    ) throws {
        let layout = PixelLayoutV4(storage: storage)
        let status = CVPixelBufferLockBaseAddress(buffer, [])
        XCTAssertEqual(status, kCVReturnSuccess)
        guard status == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let frameWidth = CVPixelBufferGetWidth(buffer)
        for (index, plane) in layout.planes.enumerated() {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, index)
            else {
                XCTFail("Missing plane \(index)")
                return
            }
            let active = try plane.activeBytesPerRow(frameWidth: frameWidth)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, index)
            let height = CVPixelBufferGetHeightOfPlane(buffer, index)
            for y in 0..<height where active < stride {
                base.advanced(by: y * stride + active)
                    .assumingMemoryBound(to: UInt8.self)
                    .update(repeating: byte, count: stride - active)
            }
        }
    }

    private func rawPlaneBytes(
        _ buffer: CVPixelBuffer,
        plane: Int
    ) throws -> Data {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        XCTAssertEqual(status, kCVReturnSuccess)
        guard status == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
            return Data()
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            * CVPixelBufferGetHeightOfPlane(buffer, plane)
        return Data(bytes: base, count: count)
    }

    private func allPlaneBytes(_ buffer: CVPixelBuffer) throws -> [Data] {
        try (0..<CVPixelBufferGetPlaneCount(buffer)).map {
            try rawPlaneBytes(buffer, plane: $0)
        }
    }

    private func replacingCanonicalUTF8(
        _ needle: String,
        with replacement: String,
        in data: Data
    ) throws -> Data {
        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: needle) else {
            throw ASHMeasurementExtractorV4Error.incompatibleHistory
        }
        return Data(text.replacingCharacters(
            in: range,
            with: replacement
        ).utf8)
    }

    private func makeTemporalFrame(
        id: String,
        ordinal: Int64,
        plane: ASHTemporalPlaneV4
    ) throws -> ASHTemporalFrameV4 {
        try ASHTemporalFrameV4(
            frameID: id,
            streamID: "rotation-stream",
            formatIdentity: ASHSHA256V4(String(repeating: "d", count: 64)),
            ordinal: ordinal,
            presentationTime: ExactRationalV4(ordinal, 30),
            luma: plane,
            tileStateRawValues: [],
            cadenceID: "progressive"
        )
    }

    private func makeFrame(
        storage: PixelStorageV4,
        width: Int,
        height: Int,
        luma: (Int, Int) -> UInt16,
        cb: (Int, Int) -> UInt16,
        cr: (Int, Int) -> UInt16
    ) throws -> PixelBufferSignalFrameV4 {
        let layout = PixelLayoutV4(storage: storage)
        let lumaLayout = layout.planes[0]
        let chromaLayout = layout.planes[1]
        var lumaSamples: [UInt16] = []
        for y in 0..<height {
            for x in 0..<width {
                lumaSamples.append(luma(x, y))
            }
        }
        let chromaWidth = try chromaLayout.width(forFrameWidth: width)
        let chromaHeight = try chromaLayout.height(forFrameHeight: height)
        var chromaSamples: [UInt16] = []
        for y in 0..<chromaHeight {
            for x in 0..<chromaWidth {
                chromaSamples.append(cb(x, y))
                chromaSamples.append(cr(x, y))
            }
        }
        return PixelBufferSignalFrameV4(
            storage: storage,
            width: width,
            height: height,
            planes: [
                try PixelBufferSignalPlaneV4(
                    width: width,
                    height: height,
                    componentsPerElement: 1,
                    componentBounds: lumaLayout.signalCodeBounds,
                    samples: lumaSamples
                ),
                try PixelBufferSignalPlaneV4(
                    width: chromaWidth,
                    height: chromaHeight,
                    componentsPerElement: 2,
                    componentBounds: chromaLayout.signalCodeBounds,
                    samples: chromaSamples
                )
            ]
        )
    }
}
