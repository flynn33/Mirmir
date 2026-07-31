import AppKit
import Foundation

extension MirmirViewModel {
    var cacheLocationIsConfigurable: Bool {
        upscalerEngine is any R13CacheLocationConfiguring
    }

    var canChangeCacheLocation: Bool {
        !jobIsRunning
            && !recoveryIsProbing
            && !recoveryMutationIsInProgress
    }

    var cacheLocationStatusMessage: String? {
        cacheLocationSelectionError ?? cacheLocationError
    }

    func chooseCacheLocation() {
        guard canChangeCacheLocation,
              let configurable =
                upscalerEngine as? any R13CacheLocationConfiguring else {
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .warning,
                    subsystem: "cache",
                    operation: "select_cache_location",
                    code: "cache_location_change_blocked"
                )
            }
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Select a cache folder or drive"
        panel.prompt = "Use for Cache"
        if cacheLocationIsCustom {
            panel.directoryURL = URL(
                fileURLWithPath: cacheLocationPath,
                isDirectory: true
            )
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        let correlationID = UUID()
        let resource = MirmirDiagnosticResourceInput(
            role: "cache_location",
            url: url,
            location: .userSelected
        )
        do {
            applyCacheLocationStatus(
                try configurable.selectCacheLocation(url)
            )
            cacheLocationSelectionError = nil
            reloadRecoverableJobsForCacheLocationChange()
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "cache",
                    operation: "select_cache_location",
                    code: "cache_location_selected",
                    correlationID: correlationID,
                    resources: [resource]
                )
            }
        } catch {
            cacheLocationSelectionError =
                userFacingCacheLocationError(error)
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "cache",
                    operation: "select_cache_location",
                    code: "cache_location_selection_failed",
                    correlationID: correlationID,
                    resources: [resource],
                    error: error
                )
            }
        }
    }

    func useDefaultCacheLocation() {
        guard canChangeCacheLocation,
              let configurable =
                upscalerEngine as? any R13CacheLocationConfiguring else {
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .warning,
                    subsystem: "cache",
                    operation: "restore_default_cache",
                    code: "cache_default_restore_blocked"
                )
            }
            return
        }
        do {
            applyCacheLocationStatus(
                try configurable.useDefaultCacheLocation()
            )
            cacheLocationSelectionError = nil
            reloadRecoverableJobsForCacheLocationChange()
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "cache",
                    operation: "restore_default_cache",
                    code: "cache_default_restored"
                )
            }
        } catch {
            cacheLocationSelectionError =
                userFacingCacheLocationError(error)
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "cache",
                    operation: "restore_default_cache",
                    code: "cache_default_restore_failed",
                    error: error
                )
            }
        }
    }

    func refreshCacheLocation() {
        guard let configurable =
            upscalerEngine as? any R13CacheLocationConfiguring else {
            return
        }
        let status = configurable.cacheLocationStatus()
        applyCacheLocationStatus(status)
        if status.availabilityError != nil {
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .warning,
                    subsystem: "cache",
                    operation: "refresh_cache_location",
                    code: "cache_location_unavailable"
                )
            }
        }
    }

    func defaultOutputURL(
        for source: SourceProfile,
        target: VideoResolution,
        codec outputCodec: OutputCodec? = nil
    ) -> URL {
        defaultOutputURL(
            for: source,
            target: target,
            in: source.url.deletingLastPathComponent(),
            codec: outputCodec
        )
    }

    func defaultOutputURL(
        for source: SourceProfile,
        target: VideoResolution,
        in directoryURL: URL,
        codec outputCodec: OutputCodec? = nil
    ) -> URL {
        let base = source.url.deletingPathExtension().lastPathComponent
        let resolvedCodec = outputCodec ?? codec
        let pathExtension =
            MediaOutputContainerPolicy.preferredPathExtension(
                codec: resolvedCodec,
                videoFormat: source.videoFormat,
                preservationCapability:
                    source.mediaPreservationCapability,
                preserveAudio:
                    source.hasAudio && preserveAudio
            )
        return directoryURL.appendingPathComponent(
            "\(base)_mirmir_\(Self.fileLabel(for: target))."
                + pathExtension
        )
    }

    func availableDefaultOutputURL(
        for source: SourceProfile,
        target: VideoResolution,
        in directoryURL: URL,
        codec outputCodec: OutputCodec? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let preferred = defaultOutputURL(
            for: source,
            target: target,
            in: directoryURL,
            codec: outputCodec
        )
        return availableOutputURL(
            preferred,
            fileManager: fileManager
        )
    }

    func availableOutputURL(
        _ preferred: URL,
        fileManager: FileManager = .default
    ) -> URL {
        guard fileManager.fileExists(atPath: preferred.path) else {
            return preferred
        }
        let stem = preferred.deletingPathExtension().lastPathComponent
        let pathExtension = preferred.pathExtension
        let directoryURL = preferred.deletingLastPathComponent()
        var suffix = 2
        while suffix < Int.max {
            let filename = pathExtension.isEmpty
                ? "\(stem)_\(suffix)"
                : "\(stem)_\(suffix).\(pathExtension)"
            let candidate = directoryURL.appendingPathComponent(
                filename,
                isDirectory: false
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
        return directoryURL.appendingPathComponent(
            "\(stem)_\(UUID().uuidString.lowercased()).\(pathExtension)",
            isDirectory: false
        )
    }

    static var unsupportedFileMessage: String {
        "Choose a local video file."
    }

    static func fileLabel(for resolution: VideoResolution) -> String {
        switch resolution {
        case .p720:
            return "720p"
        case .p1080:
            return "1080p"
        case .p1440:
            return "1440p"
        case .p2160:
            return "2160p"
        default:
            return "\(resolution.width)x\(resolution.height)"
        }
    }

    static var sourceOutputConflictMessage: String {
        "The output file must be different from the source video."
    }

    static var existingOutputConflictMessage: String {
        "A file already exists at this destination. Choose a new output "
            + "filename so the existing video remains unchanged."
    }

    static func urlsReferToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        FileURLIdentity.refersToSameFile(lhs, rhs)
    }

    private func applyCacheLocationStatus(
        _ status: R13CacheLocationStatus
    ) {
        cacheLocationPath = status.selection.displayPath
        cacheLocationIsCustom = status.selection.isCustom
        cacheLocationError = status.availabilityError
    }

    private func reloadRecoverableJobsForCacheLocationChange() {
        cancelRecoveryProbe()
        retryableFailedJob = nil
        recoverableJobs = []
        recoveryReauthorizationRequiredIDs = []
        recoveryRejectedEntryCount = 0
        recoveryError = nil
        loadRecoverableJobs()
        refreshReleaseDiagnostics()
    }

    private func userFacingCacheLocationError(
        _ error: Error
    ) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return R13CacheLocationError.locationUnavailable
            .localizedDescription
    }

    func clearOutputSelection() {
        outputURL = nil
        outputSelectionError = nil
    }

    func userFacingProbeError(_ error: Error) -> String {
        "Mirmir could not read this video. \(String(describing: error))"
    }

    func unsupportedResolutionMessage(
        _ resolution: VideoResolution
    ) -> String {
        "Mirmir cannot derive a larger output through 2160p "
            + "for source geometry \(resolution)."
    }
}
