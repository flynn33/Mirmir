import XCTest
@testable import Mirmir

final class ASHLockedFramePipelineV3Tests: XCTestCase {
    func testProcessesEveryPlaneForBothRoutesWithLockedConstructionCounts() throws {
        for route in ASHSpatialRouteV2.allCases {
            let fixture = try loadedFixture(route)
            let source = try codeFrame()
            let output = try ASHLockedFramePipelineV3.process(input(
                source: source,
                fixture: fixture
            ))
            let lumaCount = output.luma.width * output.luma.height
            let chromaCount = output.cb.width * output.cb.height

            XCTAssertEqual(output.summary.route, route)
            XCTAssertEqual(output.summary.reconstructedLumaSampleCount, lumaCount)
            XCTAssertEqual(output.summary.reconstructedChromaSampleCount, chromaCount * 2)
            XCTAssertEqual(output.summary.primaryEvaluationCount, lumaCount + chromaCount * 2)
            XCTAssertLessThanOrEqual(output.summary.maximumOperatorEvaluations, 2)
            XCTAssertEqual(output.summary.temporalStateCount, 0)
            XCTAssertEqual(output.summary.constructionCounters.analyzerTraversalCount, 1)
            XCTAssertEqual(
                output.summary.constructionCounters.dispatchGridConstructionCount,
                2
            )
            XCTAssertEqual(output.summary.constructionCounters.lutLoadCount, 0)
            XCTAssertEqual(output.summary.constructionCounters.jsonParsingCount, 0)
            XCTAssertEqual(output.summary.constructionCounters.runtimeTreeGenerationCount, 0)
            XCTAssertEqual(output.summary.constructionCounters.runtimePathConstructionCount, 0)
            XCTAssertTrue(output.luma.normalizedSamples.allSatisfy(isLegal))
            XCTAssertTrue(output.cb.normalizedSamples.allSatisfy(isLegal))
            XCTAssertTrue(output.cr.normalizedSamples.allSatisfy(isLegal))
            XCTAssertNotEqual(output.cb.normalizedSamples, output.cr.normalizedSamples)
        }
    }

    func testRepeatedInputAndArtifactsProduceBitIdenticalOutput() throws {
        let fixture = try loadedFixture(.direct2x)
        let pipelineInput = try input(source: codeFrame(), fixture: fixture)

        let first = try ASHLockedFramePipelineV3.process(pipelineInput)
        let second = try ASHLockedFramePipelineV3.process(pipelineInput)

        XCTAssertEqual(first, second)
    }

    func testSourceAlignedLumaSitesPreserveExactNormalizedCodes() throws {
        let fixture = try loadedFixture(.direct2x)
        let source = try codeFrame()
        let output = try ASHLockedFramePipelineV3.process(input(
            source: source,
            fixture: fixture
        ))
        let normalized = try ASHNV12FrameCodec.normalizedPlane(
            source.luma,
            channel: .luma
        )

        for sourceRow in 0..<source.luma.height {
            for sourceColumn in 0..<source.luma.width {
                let sourceIndex = (sourceRow * source.luma.width) + sourceColumn
                let outputIndex = (sourceRow * 2 * output.luma.width) + sourceColumn * 2
                XCTAssertEqual(
                    output.luma.normalizedSamples[outputIndex].bitPattern,
                    normalized.samples[sourceIndex].bitPattern
                )
            }
        }
        XCTAssertGreaterThan(output.summary.sourceAlignedPreservationCount, 0)
    }

    func testRejectsRangeSitingAndDestinationMismatchBeforeEvaluation() throws {
        let fixture = try loadedFixture(.direct2x)
        let source = try codeFrame()
        let valid = try input(source: source, fixture: fixture)

        assertPipelineError(
            ASHLockedFramePipelineInputV3(
                source: source,
                destinationGeometry: valid.destinationGeometry,
                destinationRange: .full,
                expectedRange: .video,
                expectedChromaSiting: .center,
                lut: fixture.loaded,
                configuration: fixture.configuration,
                analyzerConfiguration: try .makeDisposableP05Reference()
            ),
            equals: .codeRangeMismatch
        )
        assertPipelineError(
            ASHLockedFramePipelineInputV3(
                source: source,
                destinationGeometry: valid.destinationGeometry,
                destinationRange: .video,
                expectedRange: .video,
                expectedChromaSiting: .left,
                lut: fixture.loaded,
                configuration: fixture.configuration,
                analyzerConfiguration: try .makeDisposableP05Reference()
            ),
            equals: .chromaSitingMismatch
        )
        assertPipelineError(
            ASHLockedFramePipelineInputV3(
                source: source,
                destinationGeometry: ASHNV12FrameGeometry(
                    lumaWidth: valid.destinationGeometry.lumaWidth + 1,
                    lumaHeight: valid.destinationGeometry.lumaHeight,
                    chromaWidth: valid.destinationGeometry.chromaWidth,
                    chromaHeight: valid.destinationGeometry.chromaHeight
                ),
                destinationRange: .video,
                expectedRange: .video,
                expectedChromaSiting: .center,
                lut: fixture.loaded,
                configuration: fixture.configuration,
                analyzerConfiguration: try .makeDisposableP05Reference()
            ),
            equals: .invalidDestinationGeometry
        )
    }

    private struct Fixture {
        let configuration: ASHLUTLockedConfigurationV3
        let loaded: ASHLUTLoadedV3
    }

    private func loadedFixture(_ route: ASHSpatialRouteV2) throws -> Fixture {
        let source = route == .direct2x
            ? try ASHLUTTestSupportV3.direct2x()
            : try ASHLUTTestSupportV3.direct3Over2()
        return Fixture(
            configuration: source.configuration,
            loaded: try ASHLUTBinaryCodecV3.load(
                source.artifact.data,
                expectedRoute: route,
                configuration: source.configuration
            )
        )
    }

    private func input(
        source: ASHNV12CodeFrame,
        fixture: Fixture
    ) throws -> ASHLockedFramePipelineInputV3 {
        let route = fixture.loaded.route
        return ASHLockedFramePipelineInputV3(
            source: source,
            destinationGeometry: ASHNV12FrameGeometry(
                lumaWidth: try route.destinationExtent(for: source.luma.width),
                lumaHeight: try route.destinationExtent(for: source.luma.height),
                chromaWidth: try route.destinationExtent(for: source.cb.width),
                chromaHeight: try route.destinationExtent(for: source.cb.height)
            ),
            destinationRange: .video,
            expectedRange: .video,
            expectedChromaSiting: .center,
            lut: fixture.loaded,
            configuration: fixture.configuration,
            analyzerConfiguration: try .makeDisposableP05Reference()
        )
    }

    private func codeFrame() throws -> ASHNV12CodeFrame {
        ASHNV12CodeFrame(
            luma: try codePlane(width: 4, height: 4) { column, row in
                UInt8(16 + ((column * 41 + row * 67) % 220))
            },
            cb: try codePlane(width: 2, height: 2) { column, row in
                UInt8(16 + ((column * 83 + row * 47) % 225))
            },
            cr: try codePlane(width: 2, height: 2) { column, row in
                UInt8(240 - ((column * 61 + row * 29) % 225))
            },
            chromaSiting: .center
        )
    }

    private func codePlane(
        width: Int,
        height: Int,
        generator: (Int, Int) -> UInt8
    ) throws -> ASHVideoAnalyzerV2CodePlane {
        try ASHVideoAnalyzerV2CodePlane(
            width: width,
            height: height,
            bytesPerRow: width,
            codes: (0..<height).flatMap { row in
                (0..<width).map { column in generator(column, row) }
            },
            range: .video
        )
    }

    private func isLegal(_ value: Double) -> Bool {
        value.isFinite && (0.0...1.0).contains(value)
    }

    private func assertPipelineError(
        _ input: ASHLockedFramePipelineInputV3,
        equals expected: ASHLockedFramePipelineErrorV3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ASHLockedFramePipelineV3.process(input),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? ASHLockedFramePipelineErrorV3,
                expected,
                file: file,
                line: line
            )
        }
    }
}
