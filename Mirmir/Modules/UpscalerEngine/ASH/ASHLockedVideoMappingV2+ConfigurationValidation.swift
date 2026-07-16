import Foundation

extension ASHLockedVideoMappingV2 {
    func validate(configuration: ASHLUTLockedConfigurationV2) throws {
        guard sha256 == configuration.mappingSHA256 else {
            throw ASHLockedVideoMappingV2Error.hashMismatch
        }
        guard configurationID == configuration.configurationID,
              boundaryMode == configuration.boundaryMode,
              direct2xAnalysisGridSourceStep
                == configuration.routes.direct2x.analysisGridSourceStep,
              direct3Over2AnalysisGridSourceStep
                == configuration.routes.direct3Over2.analysisGridSourceStep else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
    }

    func validate(configuration: ASHLUTLockedConfigurationV3) throws {
        guard sha256.hex == configuration.mappingSHA256.hex else {
            throw ASHLockedVideoMappingV2Error.hashMismatch
        }
        guard status == .lockedBeforeP07,
              configurationID == configuration.configurationID,
              boundaryMode == configuration.boundaryMode,
              direct2xAnalysisGridSourceStep
                == configuration.routes.direct2x.analysisGridSourceStep,
              direct3Over2AnalysisGridSourceStep
                == configuration.routes.direct3Over2.analysisGridSourceStep else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
    }
}
