import XCTest
@testable import Mirmir

final class ASHSpatialTelemetryV2Tests: XCTestCase {
    func test_referencePipelineRecordsBoundedProductionDispatchPath() throws {
        let recorder = DefaultASHTelemetryRecorder(emitsSignposts: false)
        recorder.beginRun(id: "v2-spatial-reference")
        let luma = try plane(width: 4, height: 4) { column, row in
            (column + row).isMultiple(of: 2) ? 24 : 224
        }
        let cb = try plane(width: 2, height: 2) { column, row in
            UInt8(48 + (column * 64) + (row * 32))
        }
        let cr = try plane(width: 2, height: 2) { column, row in
            UInt8(208 - (column * 48) - (row * 24))
        }

        let result = try ASHSpatialReferencePipelineV2.process(
            ASHSpatialReferenceInputV2(
                luma: luma,
                cb: cb,
                cr: cr,
                chromaSiting: .center,
                route: .direct2x,
                runtimeConfiguration: .developmentP05,
                analyzerConfiguration: try .makeDisposableP05Reference(),
                operatorParameters: .p05DevelopmentOnly,
                stateInputEnabled: true
            ),
            telemetry: recorder
        )
        let snapshot = recorder.finish(status: .success, message: nil)

        XCTAssertEqual(result.summary.runtimeTreeGenerationCount, 0)
        XCTAssertLessThanOrEqual(result.summary.maxOperatorEvaluations, 2)
        XCTAssertEqual(snapshot.ash.runtimeTreeGenerations, 0)
        XCTAssertEqual(snapshot.ash.stateHistogram.reduce(0, +), 16)
        XCTAssertEqual(snapshot.ash.candidateCounts.moreThanTwo, 0)
        XCTAssertEqual(snapshot.ash.candidateCounts.one + snapshot.ash.candidateCounts.two, 16 * 8)
        XCTAssertEqual(snapshot.ash.decoder.exact, 16 * 8)
        XCTAssertEqual(snapshot.ash.decoder.correctedOneBit, 0)
        XCTAssertEqual(snapshot.ash.decoder.rejected, 0)
        XCTAssertEqual(try stage(.analyzeLuma, in: snapshot).count, 1)
        XCTAssertEqual(try stage(.analyzeChroma, in: snapshot).count, 1)
        XCTAssertEqual(try stage(.statePack, in: snapshot).count, 1)
        XCTAssertEqual(try stage(.dispatchDecode, in: snapshot).count, 1)
        XCTAssertEqual(try stage(.reconstructLuma, in: snapshot).count, 1)
        XCTAssertEqual(try stage(.reconstructChroma, in: snapshot).count, 2)
        XCTAssertEqual(try stage(.telemetryReduce, in: snapshot).count, 1)
        let stateObservation = try XCTUnwrap(snapshot.media.first {
            $0.kind == "ash_v2_state_analysis"
        })
        XCTAssertEqual(stateObservation.details["analysis_sample_count"], "16")
        XCTAssertEqual(stateObservation.details["invalid_parity_count"], "0")
        XCTAssertEqual(stateObservation.details["temporal_history_used"], "false")
        XCTAssertNotNil(stateObservation.details["spatial_state_transition_count"])
        XCTAssertNil(stateObservation.details["state_transition_count"])
        XCTAssertEqual(
            stateObservation.details["hysteresis_forced_off_without_temporal_evidence"],
            "16"
        )
        let dispatchObservation = try XCTUnwrap(snapshot.media.first {
            $0.kind == "ash_v2_dispatch_cache"
        })
        XCTAssertEqual(dispatchObservation.details["analysis_cell_count"], "16")
        XCTAssertEqual(dispatchObservation.details["luma_dispatch_count"], "64")
        XCTAssertEqual(dispatchObservation.details["chroma_dispatch_count"], "64")
        XCTAssertEqual(dispatchObservation.details["luma_phase_count"], "4")
        XCTAssertEqual(dispatchObservation.details["chroma_phase_count"], "4")
        XCTAssertTrue(snapshot.result.balancedIntervals)
    }

    private func plane(
        width: Int,
        height: Int,
        generator: (Int, Int) -> UInt8
    ) throws -> ASHVideoAnalyzerV2CodePlane {
        var codes: [UInt8] = []
        for row in 0..<height {
            for column in 0..<width {
                codes.append(generator(column, row))
            }
        }
        return try ASHVideoAnalyzerV2CodePlane(
            width: width,
            height: height,
            bytesPerRow: width,
            codes: codes,
            range: .video
        )
    }

    private func stage(
        _ name: ASHTelemetryStage,
        in snapshot: ASHTelemetrySnapshot
    ) throws -> ASHStageTimingSnapshot {
        try XCTUnwrap(snapshot.stages.first { $0.name == name })
    }
}
