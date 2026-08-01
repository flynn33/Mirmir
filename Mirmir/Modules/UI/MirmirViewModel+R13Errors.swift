import Foundation

extension MirmirViewModel {
    func userFacingJobError(_ error: Error) -> String {
        if let cacheError = error as? R13CacheLocationError {
            return cacheError.localizedDescription
        }
        if let restartError = error as? R13RestartJobError {
            return userFacingRestartError(restartError)
        }
        if let hardeningError = error as? R13ReleaseHardeningError {
            return userFacingHardeningError(hardeningError)
        }
        if let environmentError = error as? R13ReleaseEnvironmentError {
            return userFacingReleaseEnvironmentError(environmentError)
        }
        if let engineError = error as? UpscalerEngineError {
            return String(describing: engineError)
        }
        return "The upscale stopped before publishing. "
            + String(describing: error)
    }

    private func userFacingRestartError(
        _ error: R13RestartJobError
    ) -> String {
        switch error {
        case .insufficientDiskSpace(let required, let available):
            return "Not enough free disk space. Mirmir needs "
                + "\(Self.fileSize(required)) and found "
                + "\(Self.fileSize(available))."
        case .reauthorizationRequired, .bookmarkCreationFailed,
             .bookmarkResolutionFailed, .securityScopeDenied:
            return "Mirmir needs permission to reopen the source or output "
                + "folder. Select them again and retry."
        case .sourceDrift:
            return "The source video changed after this job started. "
                + "Start a new upscale so cached frames cannot be mixed."
        case .prepublicationReceiptConflict:
            return "The completed output did not match its verified "
                + "prepublication receipt, so Mirmir did not accept it."
        default:
            return "The restart-safe job record could not be verified. "
                + String(describing: error)
        }
    }

    private func userFacingHardeningError(
        _ error: R13ReleaseHardeningError
    ) -> String {
        switch error {
        case .resourceRejected(let rejection):
            switch rejection {
            case .insufficientDisk:
                return "Free disk space fell below the safe processing limit."
            case .insufficientMemory:
                return "Free memory fell below the safe processing limit."
            case .thermalLimitExceeded:
                return "This Mac reached the thermal safety limit. "
                    + "Let it cool, then resume the interrupted job."
            case .duplicateActiveJob, .concurrencyLimitReached:
                return "Another upscale is already using the release engine."
            case .resourceArithmeticOverflow:
                return "The requested resource size could not be represented "
                    + "safely."
            }
        case .resourceProbeFailed(let probe):
            return "Mirmir could not measure \(probe.rawValue) capacity."
        case .resourceLeaseUnavailable:
            return "The job lost its resource reservation and stopped safely."
        case .diskReservationExceeded:
            return "The verified cache reservation was exhausted, so the job "
                + "stopped safely before publication."
        case .outputFrameCountMismatch(let expected, let actual):
            return "The source contains \(actual) frames, but the verified "
                + "restart record requires \(expected)."
        case .injectedFault:
            return "A deterministic release fault test stopped the job "
                + "before publication."
        case .arithmeticOverflow:
            return "The requested job size could not be represented safely."
        }
    }

    private func userFacingReleaseEnvironmentError(
        _ error: R13ReleaseEnvironmentError
    ) -> String {
        switch error {
        case .applicationSupportDirectoryUnavailable:
            return "Mirmir could not access its Application Support folder, "
                + "so the upscale did not start."
        case .applicationIdentityUnavailable:
            return "Mirmir could not verify this app build's release identity, "
                + "so the upscale did not start."
        case .frameworkIdentityUnavailable:
            return "Mirmir could not verify the Apple processing framework "
                + "required by this mode, so the upscale did not start."
        case .runtimeIdentityUnavailable:
            return "Mirmir could not verify the current macOS runtime identity, "
                + "so the upscale did not start."
        case .frameCountReaderFailed, .frameCountUnavailable:
            return "Mirmir could not determine the source video's exact frame "
                + "count, so the upscale did not start."
        case .memoryProbeFailed:
            return "Mirmir could not measure available memory, so the upscale "
                + "did not start safely."
        case .arithmeticOverflow:
            return "The source or resource measurements were too large to "
                + "represent safely, so the upscale did not start."
        }
    }

    private static func fileSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .file
        )
    }
}
