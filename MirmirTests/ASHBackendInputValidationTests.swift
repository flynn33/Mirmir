import Foundation
import XCTest
@testable import Mirmir

final class ASHBackendInputValidationTests: XCTestCase {
    @available(macOS 15.4, *)
    func test_defaultUpscalerRejectsInputOutputCollision() throws {
        let service = DefaultUpscalerEngineService(
            media: NoopMediaPipelineService(),
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            backendFactory: ASHDevelopmentUpscaleBackendFactory()
        )
        let fileURL = URL(fileURLWithPath: "/tmp/source.mp4")
        let job = UpscaleJob(
            inputURL: fileURL,
            outputURL: fileURL,
            targetResolution: .p2160,
            preserveAudio: false
        )

        XCTAssertThrowsError(try service.submit(job)) { error in
            guard let engineError = error as? UpscalerEngineError,
                  case .inputOutputCollision = engineError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @available(macOS 15.4, *)
    func test_defaultUpscalerRejectsAnExistingOutputBeforeStarting()
        throws {
        let service = DefaultUpscalerEngineService(
            media: NoopMediaPipelineService(),
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            backendFactory: ASHDevelopmentUpscaleBackendFactory()
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mp4")
        let outputURL = directory.appendingPathComponent("output.mp4")
        try Data("source".utf8).write(to: sourceURL)
        try Data("existing".utf8).write(to: outputURL)
        let job = UpscaleJob(
            inputURL: sourceURL,
            outputURL: outputURL,
            targetResolution: .p2160,
            preserveAudio: false
        )

        XCTAssertThrowsError(try service.submit(job)) { error in
            guard let engineError = error as? UpscalerEngineError,
                  case .outputAlreadyExists = engineError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
