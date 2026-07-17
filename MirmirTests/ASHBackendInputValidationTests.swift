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
}
